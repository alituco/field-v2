import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clans/clan_widgets.dart';
import '../core/user_facing_error.dart';
import 'dev_user_switcher_sheet.dart';
import 'edit_profile_screen.dart';
import 'profile.dart';
import 'profile_connections_screen.dart';
import 'profile_repository.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.profileRepository,
    this.profileId,
    this.devModeEnabled = false,
    this.onSwitchUser,
    this.isSigningOut = false,
    this.onSignOut,
  });

  final ProfileRepository profileRepository;
  final String? profileId;
  final bool devModeEnabled;
  final Future<void> Function(String profileId)? onSwitchUser;
  final bool isSigningOut;
  final VoidCallback? onSignOut;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<PlayerProfile> _profileFuture;
  PlayerProfile? _latestProfile;

  bool get _isCurrentProfile => widget.profileId == null;

  @override
  void initState() {
    super.initState();
    _profileFuture = _loadProfile();
  }

  Future<PlayerProfile> _loadProfile() async {
    final profile = _isCurrentProfile
        ? await widget.profileRepository.getCurrentProfile()
        : await widget.profileRepository.getProfile(widget.profileId!);
    _latestProfile = profile;
    return profile;
  }

  Future<void> _refresh() async {
    try {
      final profile = await _loadProfile();
      if (!mounted) return;
      setState(() {
        _profileFuture = Future.value(profile);
      });
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() {
        _profileFuture = Future.error(error, stackTrace);
      });
    }
  }

  Future<void> _copyProfileHandle() async {
    final profile = _latestProfile;
    if (profile == null) return;

    await Clipboard.setData(ClipboardData(text: '@${profile.username}'));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('@${profile.username} copied')));
  }

  Future<void> _openConnections(ProfileConnectionTab tab) async {
    final counts = await Navigator.of(context).push<ProfileConnectionCounts>(
      MaterialPageRoute<ProfileConnectionCounts>(
        builder: (_) => ProfileConnectionsScreen(
          profileRepository: widget.profileRepository,
          initialTab: tab,
        ),
      ),
    );
    if (!mounted) return;

    if (counts != null && _latestProfile != null) {
      final updatedProfile = _latestProfile!.copyWith(
        followingCount: counts.followingCount,
        fansCount: counts.fansCount,
      );
      _latestProfile = updatedProfile;
      setState(() {
        _profileFuture = Future.value(updatedProfile);
      });
      return;
    }

    final next = _loadProfile();
    setState(() {
      _profileFuture = next;
    });
  }

  Future<void> _openEditProfile() async {
    final profile = _latestProfile;
    if (profile == null) return;

    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => EditProfileScreen(
          profile: profile,
          profileRepository: widget.profileRepository,
        ),
      ),
    );
    if (changed == true && mounted) {
      final next = _loadProfile();
      setState(() {
        _profileFuture = next;
      });
    }
  }

  Future<void> _openDevUserSwitcher() async {
    final profile = _latestProfile;
    final onSwitchUser = widget.onSwitchUser;
    if (profile == null || onSwitchUser == null) return;

    await showDevUserSwitcher(
      context: context,
      profileRepository: widget.profileRepository,
      currentUserId: profile.id,
      onSwitchUser: onSwitchUser,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FieldHeaderOverlay(
      header: FieldPageHeader(
        title: 'Profile',
        showBack: !_isCurrentProfile,
        onBack: _isCurrentProfile ? null : () => Navigator.of(context).pop(),
        rightAction: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isCurrentProfile) ...[
              if (widget.devModeEnabled && widget.onSwitchUser != null) ...[
                _HeaderIconButton(
                  icon: Icons.switch_account_rounded,
                  tooltip: 'Switch dev user',
                  onPressed: _openDevUserSwitcher,
                ),
                const SizedBox(width: 8),
              ],
              _HeaderIconButton(
                icon: Icons.edit_rounded,
                tooltip: 'Edit profile',
                onPressed: _openEditProfile,
              ),
              const SizedBox(width: 8),
            ],
            _HeaderIconButton(
              icon: Icons.ios_share_rounded,
              tooltip: 'Share profile',
              onPressed: _copyProfileHandle,
            ),
          ],
        ),
      ),
      child: FutureBuilder<PlayerProfile>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _ProfileLoadingView();
          }

          if (snapshot.hasError || !snapshot.hasData) {
            return _ProfileErrorView(
              message: userFacingError(
                snapshot.error,
                fallback: 'We could not load this profile. Try again.',
              ),
              onRetry: () {
                final next = _loadProfile();
                setState(() {
                  _profileFuture = next;
                });
              },
            );
          }

          final profile = snapshot.data!;
          return RefreshIndicator(
            color: fieldEmerald600,
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: fieldHeaderAwarePadding(
                context,
                top: 16,
                bottom: _isCurrentProfile ? 124 : 32,
              ),
              children: [
                _IdentityCard(
                  profile: profile,
                  onOpenFollowing: _isCurrentProfile
                      ? () => _openConnections(ProfileConnectionTab.following)
                      : null,
                  onOpenFans: _isCurrentProfile
                      ? () => _openConnections(ProfileConnectionTab.fans)
                      : null,
                ),
                const SizedBox(height: 12),
                _StatsRow(profile: profile),
                if (profile.highlights.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _HighlightsCard(highlights: profile.highlights),
                ],
                if (profile.career.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _CareerCard(entries: profile.career),
                ],
                if (_isCurrentProfile && widget.onSignOut != null) ...[
                  const SizedBox(height: 16),
                  _SignOutButton(
                    isSigningOut: widget.isSigningOut,
                    onSignOut: widget.onSignOut!,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.profile,
    required this.onOpenFollowing,
    required this.onOpenFans,
  });

  final PlayerProfile profile;
  final VoidCallback? onOpenFollowing;
  final VoidCallback? onOpenFans;

  @override
  Widget build(BuildContext context) {
    final clan = profile.clan;

    return _ProfileCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ProfileAvatar(profile: profile, size: 80),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      profile.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray900,
                        fontSize: 20,
                        height: 1.05,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '@${profile.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fieldGray400,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 9),
                    if (clan == null)
                      const Text(
                        'No clan',
                        style: TextStyle(
                          color: fieldGray400,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      )
                    else
                      _ClanLine(clan: clan),
                  ],
                ),
              ),
            ],
          ),
          if (profile.bio.isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              profile.bio,
              style: const TextStyle(
                color: fieldGray600,
                fontSize: 14,
                height: 1.45,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 18),
          const Divider(height: 1, color: fieldGray100),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _SocialCount(
                  value: profile.followingCount,
                  label: 'Following',
                  onTap: onOpenFollowing,
                ),
              ),
              Container(width: 1, height: 32, color: fieldGray100),
              Expanded(
                child: _SocialCount(
                  value: profile.fansCount,
                  label: 'Fans',
                  onTap: onOpenFans,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClanLine extends StatelessWidget {
  const _ClanLine({required this.clan});

  final ProfileClan clan;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(clan.emblem, style: const TextStyle(fontSize: 16, height: 1)),
        Text(
          clan.name,
          style: const TextStyle(
            color: fieldGray700,
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          clan.tag,
          style: const TextStyle(
            color: fieldGray400,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        TierLabelBadge(rank: clan.rank, small: true),
      ],
    );
  }
}

class _SocialCount extends StatelessWidget {
  const _SocialCount({
    required this.value,
    required this.label,
    required this.onTap,
  });

  final int value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            Text(
              value.toString(),
              style: const TextStyle(
                color: fieldGray900,
                fontSize: 20,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: fieldGray400,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.7,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.profile});

  final PlayerProfile profile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(value: profile.appearances, label: 'Apps'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(value: profile.goals, label: 'Goals'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(value: profile.assists, label: 'Assists'),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return _ProfileCard(
      borderRadius: 18,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Column(
        children: [
          Text(
            value.toString(),
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 24,
              height: 1,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: fieldGray400,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _HighlightsCard extends StatelessWidget {
  const _HighlightsCard({required this.highlights});

  final List<ProfileHighlight> highlights;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.movie_creation_outlined,
                  color: fieldGray400,
                  size: 16,
                ),
                const SizedBox(width: 8),
                const Text(
                  'HIGHLIGHTS',
                  style: TextStyle(
                    color: fieldGray700,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                Text(
                  '${highlights.length} clips',
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          for (var index = 0; index < highlights.length; index++) ...[
            if (index > 0)
              const Divider(height: 1, indent: 20, color: fieldGray100),
            _HighlightRow(highlight: highlights[index]),
          ],
        ],
      ),
    );
  }
}

class _HighlightRow extends StatelessWidget {
  const _HighlightRow({required this.highlight});

  final ProfileHighlight highlight;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(highlight.title)));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 80,
                height: 56,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _NetworkImageFill(url: highlight.thumbnailUrl),
                    ColoredBox(color: Colors.black.withValues(alpha: 0.20)),
                    Center(
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.84),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          color: Colors.black,
                          size: 20,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          highlight.duration,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    highlight.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: fieldGray900,
                      fontSize: 14,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      const Icon(
                        Icons.remove_red_eye_outlined,
                        color: fieldGray400,
                        size: 13,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _viewsLabel(highlight.views, highlight.clanTag),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: fieldGray400,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
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

class _CareerCard extends StatelessWidget {
  const _CareerCard({required this.entries});

  final List<ProfileCareerEntry> entries;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Row(
              children: [
                Icon(Icons.history_rounded, color: fieldGray400, size: 16),
                SizedBox(width: 8),
                Text(
                  'CAREER',
                  style: TextStyle(
                    color: fieldGray700,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          for (var index = 0; index < entries.length; index++) ...[
            if (index > 0)
              const Divider(height: 1, indent: 20, color: fieldGray100),
            _CareerRow(entry: entries[index]),
          ],
        ],
      ),
    );
  }
}

class _CareerRow extends StatelessWidget {
  const _CareerRow({required this.entry});

  final ProfileCareerEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: fieldGray100,
              border: Border.all(color: fieldGray100),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(entry.emblem, style: const TextStyle(fontSize: 20)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.clanName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: fieldGray900,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (entry.isCurrent) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD1FAE5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'NOW',
                          style: TextStyle(
                            color: fieldEmerald600,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  entry.period,
                  style: const TextStyle(
                    color: fieldGray400,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 14,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                  children: [
                    TextSpan(text: entry.goals.toString()),
                    const TextSpan(
                      text: ' G',
                      style: TextStyle(
                        color: fieldGray400,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${entry.apps} apps',
                style: const TextStyle(
                  color: fieldGray400,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile, required this.size});

  final PlayerProfile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = profile.avatarUrl;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [fieldEmerald500, fieldBlue600],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: avatarUrl == null || avatarUrl.isEmpty
            ? _AvatarInitials(profile: profile, size: size)
            : Image.network(
                avatarUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    _AvatarInitials(profile: profile, size: size),
              ),
      ),
    );
  }
}

class _AvatarInitials extends StatelessWidget {
  const _AvatarInitials({required this.profile, required this.size});

  final PlayerProfile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        profile.initials,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.34,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _NetworkImageFill extends StatelessWidget {
  const _NetworkImageFill({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const _ImageFallback();
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => const _ImageFallback(),
    );
  }
}

class _ImageFallback extends StatelessWidget {
  const _ImageFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [fieldEmerald500, fieldBlue600],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = 24,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray100),
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: _ProfileCard(child: child),
    );
  }
}

class _SignOutButton extends StatelessWidget {
  const _SignOutButton({required this.isSigningOut, required this.onSignOut});

  final bool isSigningOut;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: isSigningOut ? null : onSignOut,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            border: Border.all(color: fieldGray200),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: fieldGray900.withValues(alpha: 0.025),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: isSigningOut
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.logout_rounded, color: fieldGray500, size: 17),
                      SizedBox(width: 8),
                      Text(
                        'Sign out',
                        style: TextStyle(
                          color: fieldGray500,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              border: Border.all(color: fieldGray200),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Icon(icon, color: fieldGray600, size: 18),
          ),
        ),
      ),
    );
  }
}

class _ProfileLoadingView extends StatelessWidget {
  const _ProfileLoadingView();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 16, bottom: 124),
      children: const [
        FieldSkeletonCard(
          height: 240,
          borderRadius: 24,
          padding: EdgeInsets.all(20),
          children: [
            Row(
              children: [
                FieldSkeletonBox(width: 80, height: 80, borderRadius: 999),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FieldSkeletonBox(height: 22, borderRadius: 6),
                      SizedBox(height: 9),
                      FieldSkeletonBox(width: 116, height: 14, borderRadius: 6),
                      SizedBox(height: 12),
                      FieldSkeletonBox(width: 178, height: 14, borderRadius: 6),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 22),
            FieldSkeletonBox(height: 14, borderRadius: 6),
            SizedBox(height: 10),
            FieldSkeletonBox(width: 220, height: 14, borderRadius: 6),
            Spacer(),
            Row(
              children: [
                Expanded(child: FieldSkeletonBox(height: 34, borderRadius: 8)),
                SizedBox(width: 20),
                Expanded(child: FieldSkeletonBox(height: 34, borderRadius: 8)),
              ],
            ),
          ],
        ),
        SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FieldSkeletonCard(
                height: 82,
                borderRadius: 18,
                padding: EdgeInsets.all(14),
                children: [
                  FieldSkeletonBox(height: 22, borderRadius: 6),
                  SizedBox(height: 10),
                  FieldSkeletonBox(height: 12, borderRadius: 6),
                ],
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: FieldSkeletonCard(
                height: 82,
                borderRadius: 18,
                padding: EdgeInsets.all(14),
                children: [
                  FieldSkeletonBox(height: 22, borderRadius: 6),
                  SizedBox(height: 10),
                  FieldSkeletonBox(height: 12, borderRadius: 6),
                ],
              ),
            ),
            SizedBox(width: 10),
            Expanded(
              child: FieldSkeletonCard(
                height: 82,
                borderRadius: 18,
                padding: EdgeInsets.all(14),
                children: [
                  FieldSkeletonBox(height: 22, borderRadius: 6),
                  SizedBox(height: 10),
                  FieldSkeletonBox(height: 12, borderRadius: 6),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: 16),
        FieldSkeletonCard(
          height: 188,
          borderRadius: 24,
          padding: EdgeInsets.all(20),
          children: [
            FieldSkeletonBox(width: 150, height: 16, borderRadius: 6),
            SizedBox(height: 18),
            Row(
              children: [
                FieldSkeletonBox(width: 80, height: 56, borderRadius: 12),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FieldSkeletonBox(height: 14, borderRadius: 6),
                      SizedBox(height: 9),
                      FieldSkeletonBox(width: 130, height: 12, borderRadius: 6),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _ProfileErrorView extends StatelessWidget {
  const _ProfileErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: fieldHeaderAwarePadding(context, top: 16, bottom: 124),
      children: [
        _ProfileCard(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Could not load profile',
                style: TextStyle(
                  color: fieldGray900,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: const TextStyle(
                  color: fieldGray500,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
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

String _viewsLabel(int views, String? clanTag) {
  final formatted = views >= 1000
      ? '${(views / 1000).toStringAsFixed(1).replaceAll('.0', '')}k'
      : views.toString();
  final suffix = clanTag == null || clanTag.isEmpty ? '' : ' - $clanTag';
  return '$formatted views$suffix';
}
