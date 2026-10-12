import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/field_loading.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import 'home_discovery_repository.dart';

class HomeDiscoveryScreen extends StatefulWidget {
  const HomeDiscoveryScreen({
    super.key,
    required this.repository,
    required this.onPlayer,
    required this.onNotification,
    this.search = false,
  });
  final HomeDiscoveryRepository repository;
  final Future<void> Function(String) onPlayer;
  final Future<void> Function(HomeNotification) onNotification;
  final bool search;

  @override
  State<HomeDiscoveryScreen> createState() => _HomeDiscoveryScreenState();
}

class _HomeDiscoveryScreenState extends State<HomeDiscoveryScreen> {
  final _query = TextEditingController();
  Timer? _debounce;
  int _request = 0;
  bool _loading = false;
  String? _error;
  List<HomePlayerResult> _players = [];
  List<HomeNotification> _notifications = [];
  final _read = <String>{};
  final _dismissed = <String>{};
  final _dismissing = <String>{};
  final _dismissErrors = <String, String>{};

  @override
  void initState() {
    super.initState();
    if (!widget.search) _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _search(String query) {
    _debounce?.cancel();
    _request++;
    setState(() {
      _players = [];
      _error = null;
      _loading = query.trim().length >= 2;
    });
    if (query.trim().length >= 2) {
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
        final players = await widget.repository.searchPlayers(_query.text);
        if (!mounted || request != _request) return;
        setState(() => _players = players);
      } else {
        final notifications = await widget.repository.notifications();
        if (!mounted || request != _request) return;
        setState(
          () => _notifications = notifications
              .where((item) => !_dismissed.contains(item.id))
              .toList(),
        );
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
    try {
      await widget.repository.markRead(item.id);
      if (mounted) setState(() => _read.add(item.id));
    } catch (_) {
      // A read receipt must not prevent opening the relevant game.
    }
    if (mounted) await widget.onNotification(item);
  }

  Future<void> _dismiss(HomeNotification item) async {
    if (_dismissing.contains(item.id)) return;
    setState(() {
      _dismissing.add(item.id);
      _dismissErrors.remove(item.id);
    });
    try {
      await widget.repository.dismiss(item.id);
      if (!mounted) return;
      setState(() {
        _dismissed.add(item.id);
        _notifications.removeWhere((notice) => notice.id == item.id);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _dismissErrors[item.id] = userFacingError(
          error,
          fallback: 'Could not resolve this notification. Tap to retry.',
        );
      });
    } finally {
      if (mounted) setState(() => _dismissing.remove(item.id));
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      appBar: AppBar(
        title: Text(
          widget.search ? 'Search players' : 'Activity',
          style: const TextStyle(
            fontFamily: 'Outfit',
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (widget.search)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
                child: TextField(
                  key: const Key('home-player-search'),
                  controller: _query,
                  autofocus: true,
                  onChanged: _search,
                  cursorColor: FieldrushAuthTheme.forest,
                  style: const TextStyle(
                    fontFamily: 'PlusJakartaSans',
                    color: FieldrushAuthTheme.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Name or @username',
                    hintStyle: const TextStyle(
                      fontFamily: 'PlusJakartaSans',
                      color: FieldrushAuthTheme.muted,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      color: FieldrushAuthTheme.forest,
                      size: 22,
                    ),
                    suffixIcon: _query.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded, size: 18),
                            color: FieldrushAuthTheme.muted,
                            onPressed: () {
                              _query.clear();
                              _search('');
                            },
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 17,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: FieldrushAuthTheme.border,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: FieldrushAuthTheme.border,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: FieldrushAuthTheme.forest,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: FieldRefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  children: [
                    if (_loading)
                      FieldLoadingContent(
                        label: widget.search
                            ? 'Searching players'
                            : 'Loading activity',
                        rows: 4,
                      ),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        style: const TextStyle(
                          color: FieldrushAuthTheme.danger,
                        ),
                      ),
                      TextButton(
                        onPressed: _load,
                        child: const Text('Try again'),
                      ),
                    ] else if (!_loading && widget.search && _players.isEmpty)
                      _empty(
                        _query.text.trim().length < 2
                            ? 'Find your people'
                            : 'No players found',
                        _query.text.trim().length < 2
                            ? 'Search by name or username.'
                            : 'Try another name or username.',
                      )
                    else if (!_loading &&
                        !widget.search &&
                        _notifications.isEmpty)
                      _empty(
                        'You’re all caught up',
                        'Game updates and invitations will appear here.',
                      ),
                    if (widget.search)
                      for (final player in _players)
                        _card(
                          ListTile(
                            key: ValueKey('home-search-player-${player.id}'),
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFFF2EFE3),
                              backgroundImage: player.avatarUrl == null
                                  ? null
                                  : NetworkImage(player.avatarUrl!),
                              child: player.avatarUrl == null
                                  ? Text(
                                      player.name.characters.firstOrNull ?? '?',
                                      style: const TextStyle(
                                        fontFamily: 'Outfit',
                                        color: FieldrushAuthTheme.forest,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    )
                                  : null,
                            ),
                            title: Text(
                              player.name,
                              style: const TextStyle(
                                fontFamily: 'Outfit',
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Text(
                              '@${player.username}',
                              style: const TextStyle(
                                fontFamily: 'PlusJakartaSans',
                                color: FieldrushAuthTheme.muted,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right_rounded,
                              color: FieldrushAuthTheme.muted,
                            ),
                            onTap: () => widget.onPlayer(player.id),
                          ),
                        )
                    else
                      for (final item in _notifications)
                        _notificationCard(item),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _notificationCard(HomeNotification item) {
    final unread = item.readAt == null && !_read.contains(item.id);
    final dismissing = _dismissing.contains(item.id);
    final error = _dismissErrors[item.id];
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('home-notification-${item.id}'),
            onTap: () => _open(item),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: unread
                          ? const Color(0xFFE4F0D5)
                          : const Color(0xFFF2EFE3),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      Icons.notifications_none_rounded,
                      size: 18,
                      color: unread
                          ? FieldrushAuthTheme.forest
                          : FieldrushAuthTheme.muted,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Outfit',
                                  color: FieldrushAuthTheme.ink,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  height: 1.15,
                                ),
                              ),
                            ),
                            if (unread) ...[
                              const SizedBox(width: 6),
                              Semantics(
                                label: 'Unread',
                                child: const SizedBox(
                                  key: ValueKey('activity-unread-dot'),
                                  width: 6,
                                  height: 6,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: FieldrushAuthTheme.forest,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          item.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'PlusJakartaSans',
                            color: FieldrushAuthTheme.muted,
                            fontWeight: FontWeight.w500,
                            fontSize: 11.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 5),
                  IconButton(
                    key: ValueKey('home-notification-resolve-${item.id}'),
                    tooltip: error == null
                        ? 'Resolve notification'
                        : 'Retry resolving notification',
                    onPressed: dismissing ? null : () => _dismiss(item),
                    color: FieldrushAuthTheme.forest,
                    iconSize: 20,
                    icon: dismissing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: FieldLoadingIndicator(
                              label: 'Resolving notification',
                            ),
                          )
                        : Icon(
                            error == null
                                ? Icons.check_circle_outline_rounded
                                : Icons.refresh_rounded,
                          ),
                  ),
                ],
              ),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(
                error,
                key: ValueKey('home-notification-resolve-error-${item.id}'),
                style: const TextStyle(
                  fontFamily: 'PlusJakartaSans',
                  color: FieldrushAuthTheme.danger,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _empty(String title, String body) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 12),
    child: Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Outfit',
            fontSize: 23,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: FieldrushAuthTheme.muted,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
  Widget _card(Widget child) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: FieldrushAuthTheme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}
