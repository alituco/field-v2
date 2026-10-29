import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/field_loading.dart';
import '../ui/fieldrush_avatar_image.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../clans/clan.dart';
import '../clans/clan_detail_screen.dart';
import '../clans/clan_repository.dart';
import '../clans/fieldrush_clan_widgets.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture_repository.dart';
import 'activity_revision.dart';
import 'home_discovery_repository.dart';

class HomeDiscoveryScreen extends StatefulWidget {
  const HomeDiscoveryScreen({
    super.key,
    required this.repository,
    required this.onPlayer,
    required this.onNotification,
    this.search = false,
    this.initialClans = false,
    this.clanRepository,
    this.fixtureRepository,
  });
  final HomeDiscoveryRepository repository;
  final Future<void> Function(String) onPlayer;
  final Future<void> Function(HomeNotification) onNotification;
  final bool search;
  final bool initialClans;
  final ClanRepository? clanRepository;
  final FixtureRepository? fixtureRepository;

  @override
  State<HomeDiscoveryScreen> createState() => _HomeDiscoveryScreenState();
}

class _HomeDiscoveryScreenState extends State<HomeDiscoveryScreen>
    with WidgetsBindingObserver {
  final _query = TextEditingController();
  Timer? _debounce;
  int _request = 0;
  bool _loading = false;
  String? _error;
  List<HomePlayerResult> _players = [];
  List<Clan> _clans = [];
  late bool _searchClans;
  late final ClanRepository _clanRepository;
  List<HomeNotification> _notifications = [];
  final _read = <String>{};
  final _dismissed = <String>{};
  final _dismissing = <String>{};
  final _dismissErrors = <String, String>{};
  bool _markingAllRead = false;
  String? _readError;
  final _pendingReads = <String, Future<bool>>{};
  final _latestActivity = <String, HomeNotification>{};
  StreamSubscription<void>? _activitySubscription;
  Timer? _activityRefresh;
  String? _openingNotificationId;

  @override
  void initState() {
    super.initState();
    _searchClans = widget.initialClans;
    _clanRepository = widget.clanRepository ?? SupabaseClanRepository();
    if (!widget.search) {
      WidgetsBinding.instance.addObserver(this);
      fieldrushActivityRevision.addListener(_scheduleActivityRefresh);
      final repository = widget.repository;
      if (repository is HomeActivityChanges) {
        _activitySubscription = (repository as HomeActivityChanges)
            .watchActivityChanges()
            .listen((_) => _scheduleActivityRefresh(), onError: (_) {});
      }
    }
    if (!widget.search || _searchClans) _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _activityRefresh?.cancel();
    _activitySubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    fieldrushActivityRevision.removeListener(_scheduleActivityRefresh);
    _query.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.search && state == AppLifecycleState.resumed) {
      _scheduleActivityRefresh();
    }
  }

  void _scheduleActivityRefresh() {
    if (!mounted || widget.search) return;
    _activityRefresh?.cancel();
    _activityRefresh = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _load();
    });
  }

  void _search(String query) {
    _debounce?.cancel();
    _request++;
    setState(() {
      _players = [];
      _clans = [];
      _error = null;
      _loading = _searchClans || query.trim().length >= 2;
    });
    if (_searchClans || query.trim().length >= 2) {
      _debounce = Timer(const Duration(milliseconds: 300), _load);
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (widget.search) {
        if (_searchClans) {
          final clans = await _clanRepository.listClans();
          if (!mounted || request != _request) return;
          final query = _query.text.trim().toLowerCase();
          setState(
            () => _clans = clans
                .where(
                  (c) =>
                      c.name.toLowerCase().contains(query) ||
                      c.tag.toLowerCase().contains(query),
                )
                .toList(),
          );
        } else {
          final players = await widget.repository.searchPlayers(_query.text);
          if (!mounted || request != _request) return;
          setState(() => _players = players);
        }
      } else {
        final notifications = await widget.repository.notifications();
        if (!mounted || request != _request) return;
        setState(() {
          _latestActivity
            ..clear()
            ..addEntries(notifications.map((item) => MapEntry(item.id, item)));
          _notifications = notifications
              .where((item) => !_dismissed.contains(item.id))
              .toList();
        });
      }
    } catch (error) {
      if (mounted && request == _request) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not load this page. Try again.',
          ),
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _open(HomeNotification item) async {
    if (_openingNotificationId != null) return;
    setState(() => _openingNotificationId = item.id);
    if (item.readAt == null && !_read.contains(item.id)) {
      setState(() => _read.add(item.id));
      unawaited(_saveRead(item.id));
    }
    String? openError;
    try {
      await widget.onNotification(item);
    } catch (error) {
      openError = userFacingError(
        error,
        fallback: 'Could not open this activity. Try again.',
      );
    } finally {
      if (mounted) {
        setState(() => _openingNotificationId = null);
        // Accepting/declining an invitation resolves it on the server. Do not
        // leave the old invitation row visible when its detail route closes.
        await _load();
        if (mounted && openError != null) {
          setState(() => _error = openError);
        }
      }
    }
  }

  Future<bool> _saveRead(String id, {bool notify = true}) async {
    final existing = _pendingReads[id];
    if (existing != null) return existing;
    final request = _persistRead(id, notify: notify);
    _pendingReads[id] = request;
    try {
      return await request;
    } finally {
      if (identical(_pendingReads[id], request)) _pendingReads.remove(id);
    }
  }

  Future<bool> _persistRead(String id, {required bool notify}) async {
    try {
      await widget.repository.markRead(id);
      if (notify) notifyFieldrushActivityChanged();
      return true;
    } catch (_) {
      // A read receipt must not prevent opening the relevant game.
      if (mounted && _latestActivity[id]?.readAt == null) {
        setState(() {
          _read.remove(id);
          _readError = 'Could not mark this activity as read. Try again.';
        });
      }
      return false;
    }
  }

  Future<void> _dismiss(HomeNotification item) async {
    if (_dismissing.contains(item.id)) return;
    setState(() {
      _dismissing.add(item.id);
      _dismissErrors.remove(item.id);
      _dismissed.add(item.id);
      _notifications.removeWhere((notice) => notice.id == item.id);
    });
    try {
      await widget.repository.dismiss(item.id);
      notifyFieldrushActivityChanged();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _dismissed.remove(item.id);
        final latest = _latestActivity[item.id];
        if (latest != null &&
            !_notifications.any((notice) => notice.id == item.id)) {
          _notifications.add(latest);
          _notifications.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        }
        _dismissErrors[item.id] = userFacingError(
          error,
          fallback: 'Could not dismiss this notification. Tap × to retry.',
        );
      });
    } finally {
      if (mounted) setState(() => _dismissing.remove(item.id));
    }
  }

  Future<void> _markAllRead() async {
    if (_markingAllRead) return;
    final unread = _notifications
        .where((item) => item.readAt == null && !_read.contains(item.id))
        .toList();
    setState(() {
      _markingAllRead = true;
      _readError = null;
      _read.addAll(unread.map((item) => item.id));
    });
    final failed = <String>[];
    await Future.wait(
      unread.map((item) async {
        try {
          if (!await _saveRead(item.id, notify: false)) failed.add(item.id);
        } catch (_) {
          failed.add(item.id);
        }
      }),
    );
    if (!mounted) return;
    setState(() {
      _markingAllRead = false;
      _read.removeAll(failed);
      if (failed.isNotEmpty) {
        _readError = 'Could not mark all activity as read. Try again.';
      }
    });
    notifyFieldrushActivityChanged();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      body: widget.search ? _searchBody() : _activityBody(),
    ),
  );

  Widget _searchBody() => SafeArea(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF3C4A38),
                    side: const BorderSide(color: FieldrushAuthTheme.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.chevron_left_rounded, size: 22),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xFFC7DD9B)),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: const [
                      BoxShadow(color: Color(0xFFEFF6E4), spreadRadius: 3),
                    ],
                  ),
                  padding: const EdgeInsets.only(left: 12, right: 8),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.search_rounded,
                        size: 17,
                        color: FieldrushAuthTheme.muted,
                      ),
                      const SizedBox(width: 8),
                      if (!_searchClans) ...[
                        Text(
                          '@',
                          style: _searchText(
                            14,
                            color: const Color(0xFF8E897A),
                          ),
                        ),
                        const SizedBox(width: 2),
                      ],
                      Expanded(
                        child: TextField(
                          key: const Key('home-player-search'),
                          controller: _query,
                          autofocus: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          textInputAction: TextInputAction.search,
                          inputFormatters: [
                            FilteringTextInputFormatter.deny(RegExp('@')),
                          ],
                          onChanged: _search,
                          cursorColor: FieldrushAuthTheme.forest,
                          style: _searchText(14),
                          decoration: InputDecoration(
                            hintText: _searchClans ? 'Clan name' : 'username',
                            hintStyle: _searchText(
                              14,
                              color: const Color(0xFF8E897A),
                            ),
                            isDense: true,
                            filled: false,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                        ),
                      ),
                      if (_query.text.isNotEmpty)
                        SizedBox(
                          width: 26,
                          height: 26,
                          child: IconButton(
                            tooltip: 'Clear search',
                            padding: EdgeInsets.zero,
                            icon: const Icon(Icons.close_rounded, size: 13),
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFFF2EFE3),
                              foregroundColor: FieldrushAuthTheme.muted,
                            ),
                            onPressed: () {
                              _query.clear();
                              _search('');
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              _searchKind(
                'Players',
                selected: !_searchClans,
                onTap: () => _chooseKind(false),
              ),
              const SizedBox(width: 7),
              _searchKind(
                'Clans',
                selected: _searchClans,
                onTap: () => _chooseKind(true),
              ),
            ],
          ),
        ),
        Expanded(
          child: FieldRefreshIndicator(
            onRefresh: _load,
            child: ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                if (_loading)
                  const FieldLoadingContent(label: 'Searching players', rows: 4)
                else if (_error != null) ...[
                  Text(
                    _error!,
                    style: _searchText(12, color: FieldrushAuthTheme.danger),
                  ),
                  TextButton(onPressed: _load, child: const Text('Try again')),
                ] else if (_searchClans
                    ? _clans.isNotEmpty
                    : _players.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      _searchClans
                          ? '${_clans.length} ${_clans.length == 1 ? 'CLAN' : 'CLANS'}'
                          : '${_players.length} ${_players.length == 1 ? 'PLAYER' : 'PLAYERS'}',
                      style: _searchText(
                        11,
                        weight: FontWeight.w800,
                        color: FieldrushAuthTheme.muted,
                      ).copyWith(letterSpacing: 1.54),
                    ),
                  ),
                  const SizedBox(height: 11),
                  Material(
                    color: Colors.white,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      side: const BorderSide(color: FieldrushAuthTheme.border),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Column(
                      children: [
                        if (_searchClans)
                          for (var i = 0; i < _clans.length; i++)
                            _searchClanRow(_clans[i], divider: i > 0)
                        else
                          for (var i = 0; i < _players.length; i++)
                            _searchPlayerRow(_players[i], divider: i > 0),
                      ],
                    ),
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 14, 12, 0),
                    child: Column(
                      children: [
                        Text(
                          _searchClans
                              ? 'No clans found'
                              : _query.text.trim().length < 2
                              ? 'Search by username'
                              : 'No player @${_query.text.trim()}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: 'Outfit',
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            height: 1.25,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _searchClans
                              ? 'Start a clan, or try another name.'
                              : _query.text.trim().length < 2
                              ? 'Every player has an @username. Names work too.'
                              : 'Check the spelling, or try their name.',
                          textAlign: TextAlign.center,
                          style: _searchText(
                            12,
                            weight: FontWeight.w600,
                            color: FieldrushAuthTheme.muted,
                          ).copyWith(height: 1.5),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  void _chooseKind(bool clans) {
    if (_searchClans == clans) return;
    _debounce?.cancel();
    setState(() {
      _searchClans = clans;
      _query.clear();
      _players = [];
      _clans = [];
      _error = null;
      _loading = clans;
    });
    _request++;
    if (clans) _load();
  }

  Future<void> _openClan(Clan clan) async {
    try {
      final membership = await _clanRepository.getMyClanMembership();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ClanDetailScreen(
            clan: clan,
            clanRepository: _clanRepository,
            fixtureRepository:
                widget.fixtureRepository ?? SupabaseFixtureRepository(),
            currentMembership: membership,
          ),
        ),
      );
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not open this clan. Try again.',
          ),
        );
      }
    }
  }

  Widget _searchClanRow(Clan clan, {required bool divider}) => Ink(
    decoration: BoxDecoration(
      border: divider
          ? const Border(top: BorderSide(color: Color(0xFFF0ECE0)))
          : null,
    ),
    child: InkWell(
      key: ValueKey('home-search-clan-${clan.id}'),
      onTap: () => _openClan(clan),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
        child: Row(
          children: [
            FieldrushClanCrest(tag: clan.tag, themeId: clan.themeId, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clan.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _searchText(
                      13.5,
                      weight: FontWeight.w800,
                    ).copyWith(height: 1.25),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${clan.memberCount} members${clan.cityName == null ? '' : ' · ${clan.cityName}'}',
                    style: _searchText(
                      10.5,
                      weight: FontWeight.w600,
                      color: FieldrushAuthTheme.muted,
                    ).copyWith(height: 1.25),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _searchKind(
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(99),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? FieldrushAuthTheme.forest : Colors.white,
        border: Border.all(
          color: selected
              ? FieldrushAuthTheme.forest
              : FieldrushAuthTheme.border,
        ),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: _searchText(
          11.5,
          weight: FontWeight.w800,
          color: selected ? Colors.white : FieldrushAuthTheme.muted,
        ),
      ),
    ),
  );

  Widget _searchPlayerRow(HomePlayerResult player, {required bool divider}) {
    final placed = player.ratingVisible;
    final meta = player.isSelf
        ? '${player.name} · You'
        : [
            player.name,
            placed
                ? divisionFromRating(player.skillRating!).label
                : 'Placement',
            if (player.cityName != null) player.cityName!,
          ].join(' · ');
    final initials = player.name
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .take(2)
        .map((s) => s.characters.first)
        .join();
    return Ink(
      decoration: BoxDecoration(
        color: player.isSelf ? const Color(0xFFEFF6E4) : Colors.white,
        border: divider
            ? const Border(top: BorderSide(color: Color(0xFFF0ECE0)))
            : null,
      ),
      child: InkWell(
        key: ValueKey('home-search-player-${player.id}'),
        onTap: () async {
          // Clear cached discovery identity before returning from player safety
          // actions; a failed refresh must not re-show an old avatar.
          setState(() {
            _players = [];
            _loading = true;
            _request++;
          });
          await widget.onPlayer(player.id);
          if (mounted) await _load();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: player.isSelf
                      ? FieldrushAuthTheme.forest
                      : const Color(0xFFF2EFE3),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: FieldrushAvatarImage(
                  size: 36,
                  url: player.avatarUrl,
                  fallback: _searchBadge(player, initials),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      _searchHandle(player.username),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _searchText(
                        13.5,
                        weight: FontWeight.w800,
                      ).copyWith(height: 1.25),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _searchText(
                        10.5,
                        weight: FontWeight.w600,
                        color: FieldrushAuthTheme.muted,
                      ).copyWith(height: 1.25),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                placed ? '${player.skillRating}' : '????',
                style: const TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  color: FieldrushAuthTheme.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchBadge(HomePlayerResult player, String initials) => Center(
    child: Text(
      player.isSelf ? 'YOU' : initials.toUpperCase(),
      style: TextStyle(
        fontFamily: 'Outfit',
        fontSize: player.isSelf ? 10 : 12,
        fontWeight: FontWeight.w800,
        height: 1,
        color: player.isSelf ? Colors.white : const Color(0xFF3C4A38),
      ),
    ),
  );

  TextSpan _searchHandle(String username) {
    final query = _query.text.trim().toLowerCase();
    final hit = query.isEmpty ? -1 : username.toLowerCase().indexOf(query);
    if (hit < 0) return TextSpan(text: '@$username');
    return TextSpan(
      children: [
        TextSpan(text: '@${username.substring(0, hit)}'),
        TextSpan(
          text: username.substring(hit, hit + query.length),
          style: const TextStyle(
            backgroundColor: Color(0xFFDDEBC4),
            color: Color(0xFF1D3A23),
          ),
        ),
        TextSpan(text: username.substring(hit + query.length)),
      ],
    );
  }

  TextStyle _searchText(
    double size, {
    FontWeight weight = FontWeight.w700,
    Color color = FieldrushAuthTheme.ink,
  }) => TextStyle(
    fontFamily: 'PlusJakartaSans',
    fontSize: size,
    fontWeight: weight,
    height: 1,
    color: color,
    letterSpacing: 0,
  );

  Widget _activityBody() => SafeArea(
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.of(context).maybePop(),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.white,
                    side: const BorderSide(color: FieldrushAuthTheme.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(
                    Icons.chevron_left,
                    size: 22,
                    color: Color(0xFF3C4A38),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Activity',
                  style: TextStyle(
                    fontFamily: 'Outfit',
                    fontSize: 18,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.18,
                    color: FieldrushAuthTheme.ink,
                  ),
                ),
              ),
              if (_notifications.any(
                (item) => item.readAt == null && !_read.contains(item.id),
              ))
                TextButton(
                  key: const ValueKey('activity-mark-all-read'),
                  onPressed: _markingAllRead ? null : _markAllRead,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 36),
                    foregroundColor: FieldrushAuthTheme.forest,
                    textStyle: clanText(11.5, weight: FontWeight.w800),
                  ),
                  child: const Text('Mark all read'),
                ),
            ],
          ),
        ),
        Expanded(
          child: FieldRefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 132),
              children: [
                if (_loading && _notifications.isEmpty)
                  const FieldLoadingContent(label: 'Loading activity', rows: 4),
                if (_readError != null)
                  Text(
                    _readError!,
                    style: clanText(
                      11,
                      color: FieldrushAuthTheme.danger,
                      height: 1.4,
                    ),
                  ),
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: clanText(
                      12,
                      color: FieldrushAuthTheme.danger,
                      height: 1.4,
                    ),
                  ),
                  TextButton(onPressed: _load, child: const Text('Try again')),
                ] else if (!_loading && _notifications.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: Text(
                      "You're all caught up.",
                      textAlign: TextAlign.center,
                      style: clanText(
                        13,
                        weight: FontWeight.w600,
                        color: const Color(0xFF6B7864),
                        height: 1.4,
                      ),
                    ),
                  ),
                for (var i = 0; i < _notifications.length; i++) ...[
                  if (i > 0)
                    const Divider(
                      height: 1,
                      thickness: 1,
                      color: FieldrushAuthTheme.border,
                    ),
                  _notificationRow(_notifications[i]),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _notificationRow(HomeNotification item) {
    final unread = item.readAt == null && !_read.contains(item.id);
    final error = _dismissErrors[item.id];
    final title = item.title.trim();
    final body = item.body.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Semantics(
              label: unread ? 'Unread' : 'Read',
              child: Container(
                key: unread ? const ValueKey('activity-unread-dot') : null,
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: unread
                      ? FieldrushAuthTheme.forest
                      : Colors.transparent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              key: ValueKey('home-notification-${item.id}'),
              onTap: _openingNotificationId == null ? () => _open(item) : null,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        if (title.isNotEmpty && title != body)
                          TextSpan(
                            text: '$title${body.isEmpty ? '' : ' '}',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        TextSpan(
                          text: body.isEmpty && title == body ? title : body,
                        ),
                      ],
                    ),
                    style: clanText(
                      13,
                      weight: unread ? FontWeight.w700 : FontWeight.w500,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _activityTime(item.createdAt),
                    style: clanText(
                      11,
                      weight: FontWeight.w600,
                      color: const Color(0xFF6B7864),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      error,
                      key: ValueKey(
                        'home-notification-resolve-error-${item.id}',
                      ),
                      style: clanText(
                        11,
                        color: FieldrushAuthTheme.danger,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 2),
          Transform.translate(
            offset: const Offset(8, -6),
            child: SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                key: ValueKey('home-notification-resolve-${item.id}'),
                tooltip: error == null
                    ? 'Dismiss'
                    : 'Retry dismissing notification',
                onPressed: _dismissing.contains(item.id)
                    ? null
                    : () => _dismiss(item),
                padding: EdgeInsets.zero,
                iconSize: 18,
                color: const Color(0xFF8E897A),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _activityTime(DateTime createdAt) {
    final now = DateTime.now();
    final local = createdAt.toLocal();
    final age = now.difference(local);
    if (age.inMinutes < 1) return 'Just now';
    if (age.inHours < 1) return '${age.inMinutes}m ago';
    if (age.inHours < 24) return '${age.inHours}h ago';
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(local.year, local.month, local.day);
    final days = today.difference(date).inDays;
    if (days == 1) return 'Yesterday';
    if (days < 7) return '$days days ago';
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${weekdays[local.weekday - 1]}, ${months[local.month - 1]} ${local.day}';
  }
}
