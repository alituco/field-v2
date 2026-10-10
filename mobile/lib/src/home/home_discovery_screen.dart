import 'dart:async';

import 'package:flutter/material.dart';

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
        setState(() => _notifications = notifications);
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
                  decoration: InputDecoration(
                    hintText: 'Name or @username',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(
                        color: FieldrushAuthTheme.border,
                      ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  children: [
                    if (_loading)
                      const Padding(
                        padding: EdgeInsets.all(30),
                        child: Center(child: CircularProgressIndicator()),
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
                            subtitle: Text('@${player.username}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => widget.onPlayer(player.id),
                          ),
                        )
                    else
                      for (final item in _notifications)
                        _card(
                          ListTile(
                            key: ValueKey('home-notification-${item.id}'),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            leading: Icon(
                              Icons.notifications_none_rounded,
                              color:
                                  item.readAt == null &&
                                      !_read.contains(item.id)
                                  ? FieldrushAuthTheme.forest
                                  : FieldrushAuthTheme.muted,
                            ),
                            title: Text(
                              item.title,
                              style: const TextStyle(
                                fontFamily: 'Outfit',
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                item.body,
                                style: const TextStyle(
                                  fontSize: 12,
                                  height: 1.5,
                                ),
                              ),
                            ),
                            onTap: () => _open(item),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

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
    padding: const EdgeInsets.only(bottom: 10),
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: FieldrushAuthTheme.border),
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}
