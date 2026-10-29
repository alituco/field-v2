import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/read_timeout.dart';
import '../core/user_facing_error.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_modal.dart';
import '../ui/fieldrush_toast.dart';
import 'player_safety_repository.dart';

const playerBlockScope =
    'Blocking hides profile content and stops following and party invitations. '
    'You may still attend the same games.';

Future<bool> confirmPlayerBlock(
  BuildContext context, {
  required bool blocked,
}) async =>
    await showFieldrushModal<bool>(
      context: context,
      builder: (context) => FieldrushModal(
        key: const ValueKey('player-block-confirmation'),
        title: blocked ? 'Block player?' : 'Unblock player?',
        description: blocked
            ? playerBlockScope
            : 'Their profile content can appear again. Previous follows will '
                  'not be restored.',
        actions: [
          FilledButton(
            key: const ValueKey('player-block-confirm'),
            style: FieldrushModal.primaryButtonStyle(destructive: blocked),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(blocked ? 'Block player' : 'Unblock player'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(false),
            style: FieldrushModal.secondaryButtonStyle(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    ) ==
    true;

class BlockedPlayersScreen extends StatefulWidget {
  const BlockedPlayersScreen({super.key, required this.repository});

  final PlayerSafetyRepository repository;

  @override
  State<BlockedPlayersScreen> createState() => _BlockedPlayersScreenState();
}

class _BlockedPlayersScreenState extends State<BlockedPlayersScreen> {
  List<BlockedPlayer>? _players;
  Object? _error;
  final _busy = <String>{};
  int _generation = 0;
  String? _viewerId;

  @override
  void didUpdateWidget(covariant BlockedPlayersScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository) ||
        _viewerId != widget.repository.currentUserId) {
      _players = null;
      _busy.clear();
      _load();
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy.isNotEmpty) {
      return;
    }
    final generation = ++_generation;
    final repository = widget.repository;
    final userId = _viewerId = repository.currentUserId;
    try {
      final players = await repository.listBlockedPlayers().timeout(
        fieldReadTimeout,
      );
      if (!mounted ||
          generation != _generation ||
          userId != widget.repository.currentUserId) {
        return;
      }
      setState(() {
        _players = players;
        _error = null;
      });
    } catch (error) {
      if (!mounted ||
          generation != _generation ||
          !identical(repository, widget.repository) ||
          userId != repository.currentUserId) {
        return;
      }
      setState(() => _error = error);
    }
  }

  Future<void> _unblock(BlockedPlayer player) async {
    if (_busy.contains(player.profileId)) {
      return;
    }
    final repository = widget.repository;
    final userId = repository.currentUserId;
    if (userId == null || userId != _viewerId) {
      return;
    }
    final confirmed = await confirmPlayerBlock(context, blocked: false);
    bool current() =>
        mounted &&
        identical(repository, widget.repository) &&
        repository.currentUserId == userId;
    if (!confirmed || !current()) {
      return;
    }
    setState(() => _busy.add(player.profileId));
    // A read started before this write cannot restore a stale list afterward.
    _generation++;
    try {
      await repository
          .setBlocked(player.profileId, blocked: false)
          .timeout(fieldReadTimeout);
      if (!current()) {
        return;
      }
      setState(() {
        _players = _players
            ?.where((value) => value.profileId != player.profileId)
            .toList();
      });
      showFieldrushToast(context, 'Player unblocked');
    } catch (error) {
      if (current()) {
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'Could not unblock this player. Try again.',
          ),
        );
      }
    } finally {
      if (current()) {
        setState(() => _busy.remove(player.profileId));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      appBar: AppBar(title: const Text('Blocked players')),
      body: FieldRefreshIndicator(
        onRefresh: _load,
        child: ListView(
          key: const ValueKey('blocked-players-screen'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(20),
          children: [
            const Text(playerBlockScope),
            const SizedBox(height: 20),
            if (_viewerId != widget.repository.currentUserId)
              const Text('Sign in again to view your blocked players.')
            else if (_error != null) ...[
              Text(
                userFacingError(
                  _error,
                  fallback: 'Could not load blocked players.',
                ),
              ),
              TextButton(onPressed: _load, child: const Text('Try again')),
            ] else if (_players == null)
              const FieldLoadingIndicator(label: 'Loading blocked players')
            else if (_players!.isEmpty)
              const Text('You have not blocked any players.')
            else
              for (final player in _players!)
                Card(
                  child: ListTile(
                    key: ValueKey('blocked-player-${player.profileId}'),
                    leading: const Icon(Icons.block),
                    title: Text(player.label),
                    trailing: TextButton(
                      key: ValueKey('unblock-${player.profileId}'),
                      onPressed: _busy.contains(player.profileId)
                          ? null
                          : () => _unblock(player),
                      child: Text(
                        _busy.contains(player.profileId)
                            ? 'Unblocking…'
                            : 'Unblock',
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    ),
  );
}

class PlayerContentRefreshScreen extends StatelessWidget {
  const PlayerContentRefreshScreen({
    super.key,
    this.error,
    required this.onRetry,
  });
  final String? error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      appBar: AppBar(),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: error == null
              ? const FieldLoadingIndicator(label: 'Refreshing player content')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: onRetry,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
        ),
      ),
    ),
  );
}
