import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/read_timeout.dart';
import '../core/user_facing_error.dart';
import '../home/field_bottom_nav.dart';
import '../ui/field_loading.dart';
import '../ui/fieldrush_toast.dart';
import 'fieldrush_referral_widgets.dart';
import 'referral_repository.dart';
import 'referral_share.dart';
import 'referrals.dart';

class FieldrushReferralsScreen extends StatefulWidget {
  const FieldrushReferralsScreen({
    super.key,
    required this.repository,
    required this.onOpenPlayer,
    this.onNavigateTab,
    this.onShare,
  });
  final ReferralRepository repository;
  final ValueChanged<String> onOpenPlayer;
  final ValueChanged<int>? onNavigateTab;
  final Future<void> Function(String code)? onShare;

  @override
  State<FieldrushReferralsScreen> createState() =>
      _FieldrushReferralsScreenState();
}

class _FieldrushReferralsScreenState extends State<FieldrushReferralsScreen>
    with WidgetsBindingObserver {
  ReferralSummary? _summary;
  ReferralLeaderboard? _board;
  List<ReferralEntry> _entries = [];
  List<ReferralFriend> _friends = [];
  int? _next;
  int? _friendsNext;
  Object? _error;
  Object? _moreError;
  Object? _friendsError;
  bool _loading = true;
  bool _loadingMore = false;
  bool _loadingFriends = false;
  int _generation = 0;
  String? _userId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(covariant FieldrushReferralsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        _userId != widget.repository.currentUserId) {
      _summary = null;
      _board = null;
      _entries = [];
      _friends = [];
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final repo = widget.repository;
    final user = _userId = repo.currentUserId;
    setState(() {
      _loading = _summary == null || _board == null;
      _error = null;
      _moreError = null;
      _friendsError = null;
      _loadingMore = false;
      _loadingFriends = false;
    });
    try {
      final result = await Future.wait<Object>([
        repo.load().timeout(fieldReadTimeout),
        repo.loadLeaderboard().timeout(fieldReadTimeout),
      ]);
      if (!_current(generation, repo, user)) return;
      setState(() {
        _summary = result[0] as ReferralSummary;
        _board = result[1] as ReferralLeaderboard;
        _entries = [..._board!.entries];
        _friends = [..._summary!.referrals];
        _next = _board!.nextOffset;
        _friendsNext = _summary!.referralsNextOffset;
        _loading = false;
      });
    } catch (error) {
      if (!_current(generation, repo, user)) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  bool _current(int generation, ReferralRepository repo, String? user) =>
      mounted &&
      generation == _generation &&
      identical(repo, widget.repository) &&
      user == widget.repository.currentUserId;

  Future<void> _more({bool friends = false}) async {
    final offset = friends ? _friendsNext : _next;
    if (offset == null || (friends ? _loadingFriends : _loadingMore)) return;
    final generation = _generation;
    final repo = widget.repository;
    final user = _userId;
    setState(() {
      if (friends) {
        _loadingFriends = true;
        _friendsError = null;
      } else {
        _loadingMore = true;
        _moreError = null;
      }
    });
    try {
      if (friends) {
        final page = await repo
            .loadReferredPlayers(offset: offset)
            .timeout(fieldReadTimeout);
        if (!_current(generation, repo, user)) return;
        setState(() {
          final ids = _friends.map((entry) => entry.person.id).toSet();
          _friends.addAll(
            page.entries.where((entry) => ids.add(entry.person.id)),
          );
          _friendsNext = page.nextOffset;
          _loadingFriends = false;
        });
      } else {
        final page = await repo
            .loadLeaderboard(offset: offset)
            .timeout(fieldReadTimeout);
        if (!_current(generation, repo, user)) return;
        setState(() {
          final ids = _entries.map((entry) => entry.person.id).toSet();
          _entries.addAll(
            page.entries.where((entry) => ids.add(entry.person.id)),
          );
          _next = page.nextOffset;
          _loadingMore = false;
        });
      }
    } catch (error) {
      if (!_current(generation, repo, user)) return;
      setState(() {
        if (friends) {
          _friendsError = error;
          _loadingFriends = false;
        } else {
          _moreError = error;
          _loadingMore = false;
        }
      });
    }
  }

  Future<void> _share() async {
    final summary = _summary;
    if (summary == null) return;
    try {
      if (widget.onShare case final share?) {
        await share(summary.ownCode);
      } else {
        await shareFieldrushReferralCode(context, summary.ownCode);
      }
    } catch (error) {
      if (mounted) {
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'Could not share your code. Try again.',
          ),
        );
      }
    }
  }

  void _player(ReferralPerson person) {
    if (person.username.isEmpty) return;
    if (person.id == _userId) {
      Navigator.of(context).pop();
    } else {
      widget.onOpenPlayer(person.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _summary;
    final board = _board;
    return _ReferralScaffold(
      onNavigateTab: widget.onNavigateTab,
      child: FieldRefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 132),
          children: [
            _ReferralHeader(
              title: 'Referrals',
              onBack: () => Navigator.of(context).pop(),
              trailing: data == null
                  ? null
                  : OutlinedButton.icon(
                      onPressed: _share,
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: referralSecondaryInk,
                        side: const BorderSide(
                          color: FieldrushAuthTheme.border,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 13,
                          vertical: 8,
                        ),
                        minimumSize: const Size(0, 32),
                        textStyle: referralText(
                          11,
                          weight: FontWeight.w800,
                          height: 1,
                        ),
                      ),
                      icon: const Icon(Icons.ios_share_rounded, size: 13),
                      label: Text(
                        data.ownCode,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: FieldLoadingContent(label: 'Loading referrals', rows: 5),
              )
            else if (_error != null && (data == null || board == null))
              _ReferralError(error: _error!, onRetry: _load)
            else if (data != null && board != null) ...[
              if (_error != null)
                _ReferralError(error: _error!, onRetry: _load),
              if (data.season.ended)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    color: referralWash,
                    border: Border.all(color: FieldrushAuthTheme.border),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${referralSeasonLabel(data.season.label)} · FINAL',
                          style: referralText(
                            12,
                            color: FieldrushAuthTheme.ink,
                            weight: FontWeight.w800,
                            tracking: .96,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          '${board.qualifiedTotal} players qualified',
                          style: referralText(11, weight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                )
              else
                ReferralPrizeBanner(summary: data),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: ReferralOfficialRulesNotice(),
              ),
              ReferralSectionLabel(
                'PRIZE PLACES',
                trailing: Text(
                  '${referralMoney(data.prizeEachMinor)} Amazon gift card each',
                  textAlign: TextAlign.right,
                  style: referralText(11, weight: FontWeight.w700, height: 1.2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 11, 16, 0),
                child: ReferralSurface(
                  child: board.prizeEntries.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 20,
                          ),
                          child: Text(
                            board.qualifiedTotal == 0
                                ? 'No players have qualified yet'
                                : 'Prize places awaiting admin review.',
                            style: referralText(12.5),
                          ),
                        )
                      : Column(
                          children: [
                            for (
                              var i = 0;
                              i < board.prizeEntries.length;
                              i++
                            ) ...[
                              if (i > 0)
                                const Divider(height: 1, color: referralLine),
                              ReferralLeaderboardRow(
                                entry: board.prizeEntries[i],
                                onTap: () =>
                                    _player(board.prizeEntries[i].person),
                                isMe:
                                    board.prizeEntries[i].person.id == _userId,
                                prize: true,
                                prizeMinor: data.prizeEachMinor,
                                minimumReferrals: data.minimumReferrals,
                              ),
                            ],
                          ],
                        ),
                ),
              ),
              if (_entries.isNotEmpty ||
                  !board.prizeEntries.any(
                    (entry) => entry.person.id == _userId,
                  )) ...[
                const ReferralSectionLabel('EVERYONE ELSE', top: 20),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 11, 16, 0),
                  child: ReferralSurface(
                    child: Column(
                      children: [
                        for (final entry in _entries.where(
                          (entry) => entry.person.id != _userId,
                        )) ...[
                          ReferralLeaderboardRow(
                            entry: entry,
                            onTap: () => _player(entry.person),
                            minimumReferrals: data.minimumReferrals,
                          ),
                          const Divider(height: 1, color: referralLine),
                        ],
                        if (_next != null || _moreError != null)
                          _MoreRows(
                            loading: _loadingMore,
                            error: _moreError,
                            onTap: () => _more(),
                          ),
                        if (!board.prizeEntries.any(
                          (entry) => entry.person.id == _userId,
                        )) ...[
                          if (_entries.any(
                            (entry) => entry.person.id != _userId,
                          ))
                            Container(
                              height: 26,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                color: referralLight,
                                border: Border(
                                  bottom: BorderSide(color: referralLine),
                                ),
                              ),
                              child: Text(
                                '···',
                                style: referralText(
                                  12,
                                  color: const Color(0xFFB3AD99),
                                  weight: FontWeight.w800,
                                  tracking: 3.6,
                                ),
                              ),
                            ),
                          ReferralLeaderboardRow(
                            entry: board.me,
                            onTap: () => Navigator.of(context).pop(),
                            isMe: true,
                            minimumReferrals: data.minimumReferrals,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              if (!data.season.ended) ...[
                ReferralSectionLabel(
                  'YOUR REFERRALS',
                  trailing: Text(
                    '${data.referralCount} played',
                    style: referralText(11.5, height: 1),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 11, 16, 0),
                  child: _friends.isEmpty
                      ? const _ReferralEmptyFriends()
                      : ReferralSurface(
                          radius: 18,
                          child: Column(
                            children: [
                              for (var i = 0; i < _friends.length; i++) ...[
                                if (i > 0)
                                  const Divider(height: 1, color: referralLine),
                                ReferralFriendRow(
                                  friend: _friends[i],
                                  onTap: () => _player(_friends[i].person),
                                ),
                              ],
                              if (_friendsNext != null || _friendsError != null)
                                _MoreRows(
                                  loading: _loadingFriends,
                                  error: _friendsError,
                                  onTap: () => _more(friends: true),
                                ),
                            ],
                          ),
                        ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(
                    'A friend counted once they finished their first game. Players needed at least ${data.minimumReferrals} to qualify. Winners get their gift cards by email.',
                    style: referralText(11.5, height: 1.5),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class FieldrushReferralCodeScreen extends StatefulWidget {
  const FieldrushReferralCodeScreen({
    super.key,
    required this.repository,
    required this.onOpenPlayer,
    this.onNavigateTab,
    this.onShare,
  });
  final ReferralRepository repository;
  final ValueChanged<String> onOpenPlayer;
  final ValueChanged<int>? onNavigateTab;
  final Future<void> Function(String code)? onShare;

  @override
  State<FieldrushReferralCodeScreen> createState() =>
      _FieldrushReferralCodeScreenState();
}

class _FieldrushReferralCodeScreenState
    extends State<FieldrushReferralCodeScreen>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController(keepScrollOffset: false);
  final _elapsed = Stopwatch();
  ReferralSummary? _summary;
  ReferralPerson? _candidate;
  String? _checkedCode;
  Object? _error;
  Object? _loadError;
  bool _loading = true;
  bool _checking = false;
  bool _claiming = false;
  int _generation = 0;
  String? _userId;
  Timer? _deadline;
  bool _expired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(covariant FieldrushReferralCodeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        _userId != widget.repository.currentUserId) {
      _summary = null;
      _candidate = null;
      _checkedCode = null;
      _input.clear();
      _claiming = false;
      _checking = false;
      _error = null;
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_claiming) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _generation++;
    _deadline?.cancel();
    _elapsed.stop();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool _current(int generation, ReferralRepository repo, String? user) =>
      mounted &&
      generation == _generation &&
      identical(repo, widget.repository) &&
      user == widget.repository.currentUserId;

  void _showTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  DateTime get _now => _summary!.serverNow.add(_elapsed.elapsed);
  bool get _canAdd =>
      _summary != null &&
      _summary!.canAddCode &&
      !_expired &&
      _summary!.entryExpiresAt.isAfter(_now);

  void _receive(ReferralSummary value) {
    _summary = value;
    _elapsed
      ..reset()
      ..start();
    _deadline?.cancel();
    _expired = !value.entryExpiresAt.isAfter(value.serverNow);
    if (_canAdd) {
      _deadline = Timer(value.entryExpiresAt.difference(_now), () {
        if (mounted) {
          setState(() => _expired = true);
          _showTop();
        }
      });
    }
  }

  Future<void> _load() async {
    if (_claiming) return;
    final generation = ++_generation;
    final repo = widget.repository;
    final user = _userId = repo.currentUserId;
    setState(() {
      _loading = _summary == null;
      _loadError = null;
      _checking = false;
    });
    try {
      final data = await repo.load().timeout(fieldReadTimeout);
      if (!_current(generation, repo, user)) return;
      setState(() {
        _receive(data);
        _loading = false;
      });
    } catch (error) {
      if (!_current(generation, repo, user)) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
  }

  Future<void> _check() async {
    final code = _input.text.trim().toUpperCase();
    if (_checking || _claiming || !_canAdd || code.length < 3) return;
    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    final repo = widget.repository;
    final user = _userId;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final person = await repo.checkCode(code).timeout(fieldReadTimeout);
      if (!_current(generation, repo, user)) return;
      setState(() {
        _candidate = person;
        _checkedCode = code;
        _checking = false;
      });
      _showTop();
    } catch (error) {
      if (!_current(generation, repo, user)) return;
      setState(() {
        _error = error;
        _checking = false;
      });
    }
  }

  Future<void> _claim() async {
    final candidate = _candidate;
    final code = _checkedCode;
    if (candidate == null || code == null || _claiming || !_canAdd) return;
    final generation = ++_generation;
    final repo = widget.repository;
    final user = _userId;
    setState(() {
      _claiming = true;
      _error = null;
    });
    try {
      // The repository owns idempotent write recovery. Read deadlines must not
      // turn an uncertain permanent link into an apparent failed submission.
      final data = await repo.claimCode(code, expectedReferrerId: candidate.id);
      if (!_current(generation, repo, user)) return;
      setState(() {
        _receive(data);
        _candidate = null;
        _checkedCode = null;
        _claiming = false;
      });
      _showTop();
    } catch (error) {
      if (!_current(generation, repo, user)) return;
      setState(() {
        _error = error;
        _claiming = false;
      });
    }
  }

  void _back() {
    if (_claiming) return;
    if (_candidate != null && _summary?.referrer == null && _canAdd) {
      setState(() {
        _candidate = null;
        _checkedCode = null;
        _error = null;
      });
      _showTop();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _share() async {
    final data = _summary;
    if (data == null) return;
    try {
      if (widget.onShare case final share?) {
        await share(data.ownCode);
      } else {
        await shareFieldrushReferralCode(context, data.ownCode);
      }
    } catch (error) {
      if (mounted) {
        showFieldrushToast(
          context,
          userFacingError(
            error,
            fallback: 'Could not share your code. Try again.',
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _summary;
    final candidate = _candidate;
    final friend = data?.referrer;
    final referrerName = friend?.username.isEmpty == true
        ? 'Your referrer'
        : friend?.firstName;
    return PopScope(
      canPop: !_claiming,
      child: _ReferralScaffold(
        onNavigateTab: _claiming && widget.onNavigateTab != null
            ? (_) {}
            : widget.onNavigateTab,
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.only(bottom: 132),
          children: [
            _ReferralHeader(
              title: friend == null ? 'Enter referral code' : 'Referral code',
              onBack: _claiming ? null : _back,
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 22),
                child: FieldLoadingContent(
                  label: 'Loading referral code',
                  rows: 2,
                ),
              )
            else if (_loadError != null && data == null)
              _ReferralError(error: _loadError!, onRetry: _load)
            else if (data != null) ...[
              if (_loadError != null)
                _ReferralError(error: _loadError!, onRetry: _load),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (friend != null) ...[
                      _label('REFERRED BY'),
                      const SizedBox(height: 12),
                      ReferralPersonCard(
                        person: friend,
                        onTap: () => widget.onOpenPlayer(friend.id),
                        linked: true,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        "Linked to your account. It can't be changed.",
                        style: referralText(11.5, height: 1.45),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        data.referrerCredited
                            ? '$referrerName received 1 referral point.'
                            : '$referrerName gets credit after your first game.',
                        style: referralText(11.5, height: 1.45),
                      ),
                      const SizedBox(height: 26),
                      ReferralSurface(
                        child: ReferralOwnCode(
                          code: data.ownCode,
                          onShare: _share,
                        ),
                      ),
                    ] else if (!_canAdd) ...[
                      ReferralSurface(
                        radius: 18,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 17),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Referral window closed',
                                style: referralOutfit(17),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Referral codes can only be added during your 7-day referral window. You can still invite friends and earn rewards when they join and play!',
                                style: referralText(
                                  12.5,
                                  color: referralSecondaryInk,
                                  height: 1.55,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      ReferralSurface(
                        child: ReferralOwnCode(
                          code: data.ownCode,
                          onShare: _share,
                        ),
                      ),
                    ] else if (candidate != null) ...[
                      _label("FRIEND'S CODE"),
                      const SizedBox(height: 12),
                      _CodeBox(
                        verified: true,
                        child: Text(
                          _checkedCode!,
                          style: referralOutfit(
                            22,
                          ).copyWith(letterSpacing: 2.2),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _label('THIS CODE BELONGS TO'),
                      const SizedBox(height: 12),
                      ReferralPersonCard(
                        person: candidate,
                        onTap: _claiming
                            ? null
                            : () => widget.onOpenPlayer(candidate.id),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 9),
                        _InlineError(error: _error!),
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        key: const ValueKey('referral-confirm'),
                        onPressed: _claiming ? null : _claim,
                        child: _claiming
                            ? const FieldLoadingIndicator(
                                label: 'Adding referral code',
                                color: Colors.white,
                              )
                            : Text("Add ${candidate.firstName}'s code"),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _claiming ? null : _back,
                        style: TextButton.styleFrom(
                          foregroundColor: FieldrushAuthTheme.muted,
                          textStyle: referralText(
                            12,
                            weight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        child: const Text('Not them? Try another code'),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "You can add one code. It can't be changed later.",
                        style: referralText(11.5, height: 1.45),
                      ),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(child: _label("FRIEND'S CODE")),
                          const SizedBox(width: 10),
                          ReferralDaysBadge(
                            expiresAt: data.entryExpiresAt,
                            now: _now,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _CodeBox(
                        error: _error != null,
                        child: Semantics(
                          label: "Friend's referral code",
                          child: TextField(
                            key: const ValueKey('referral-code-input'),
                            controller: _input,
                            enabled: !_checking,
                            style: referralOutfit(
                              22,
                            ).copyWith(letterSpacing: 2.2),
                            textCapitalization: TextCapitalization.characters,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.done,
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                RegExp(r'[a-zA-Z0-9._]'),
                              ),
                              LengthLimitingTextInputFormatter(20),
                              _UppercaseFormatter(),
                            ],
                            decoration: InputDecoration(
                              hintText: 'MARCUSK',
                              hintStyle: referralOutfit(22).copyWith(
                                color: FieldrushAuthTheme.muted.withValues(
                                  alpha: .55,
                                ),
                                letterSpacing: 2.2,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                              ),
                              isDense: true,
                            ),
                            onChanged: (_) => setState(() => _error = null),
                            onSubmitted: (_) => _check(),
                          ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 9),
                        _InlineError(error: _error!),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        "A code is your friend's username. You can add one, and it can't be changed later.",
                        style: referralText(11.5, height: 1.45),
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        key: const ValueKey('referral-check'),
                        onPressed: _checking || _input.text.length < 3
                            ? null
                            : _check,
                        style: FilledButton.styleFrom(
                          disabledBackgroundColor: FieldrushAuthTheme.border,
                          disabledForegroundColor: const Color(0xFF8E897A),
                        ),
                        child: _checking
                            ? const FieldLoadingIndicator(
                                label: 'Checking referral code',
                              )
                            : const Text('Check code'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _label(String value) => Text(
    value,
    style: referralText(10, weight: FontWeight.w800, tracking: 1.4, height: 1),
  );
}

String referralSeasonLabel(String label) =>
    RegExp(r'^S\d+$', caseSensitive: false).hasMatch(label)
    ? 'SEASON ${label.substring(1)}'
    : label.toUpperCase();

class _ReferralScaffold extends StatelessWidget {
  const _ReferralScaffold({required this.child, this.onNavigateTab});
  final Widget child;
  final ValueChanged<int>? onNavigateTab;

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(child: child),
            if (onNavigateTab != null &&
                MediaQuery.viewInsetsOf(context).bottom == 0)
              Align(
                alignment: Alignment.bottomCenter,
                child: FieldBottomNav(
                  selectedIndex: 4,
                  onSelected: onNavigateTab!,
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _ReferralHeader extends StatelessWidget {
  const _ReferralHeader({
    required this.title,
    required this.onBack,
    this.trailing,
  });
  final String title;
  final VoidCallback? onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
    child: Row(
      children: [
        SizedBox.square(
          dimension: 36,
          child: IconButton(
            tooltip: 'Back',
            onPressed: onBack,
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: referralSecondaryInk,
              side: const BorderSide(color: FieldrushAuthTheme.border),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.chevron_left_rounded, size: 22),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(title, style: referralOutfit(18))),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Align(alignment: Alignment.centerRight, child: trailing!),
          ),
        ],
      ],
    ),
  );
}

class _CodeBox extends StatelessWidget {
  const _CodeBox({
    required this.child,
    this.verified = false,
    this.error = false,
  });
  final Widget child;
  final bool verified;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 58),
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(
        color: error
            ? FieldrushAuthTheme.danger
            : verified
            ? FieldrushAuthTheme.forest
            : FieldrushAuthTheme.ink,
        width: 1.5,
      ),
      borderRadius: BorderRadius.circular(15),
    ),
    child: Row(
      children: [
        Expanded(child: child),
        if (verified) ...[
          const SizedBox(width: 10),
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: FieldrushAuthTheme.forest,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 17,
              color: Colors.white,
            ),
          ),
        ],
      ],
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.error});
  final Object error;
  @override
  Widget build(BuildContext context) => Text(
    userFacingError(
      error,
      fallback: 'Could not check your referral code. Try again.',
    ),
    style: referralText(
      11.5,
      color: FieldrushAuthTheme.danger,
      weight: FontWeight.w700,
    ),
  );
}

class _ReferralError extends StatelessWidget {
  const _ReferralError({required this.error, required this.onRetry});
  final Object error;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          userFacingError(
            error,
            fallback: 'Could not load referrals. Try again.',
          ),
          style: referralText(12, color: FieldrushAuthTheme.danger),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}

class _MoreRows extends StatelessWidget {
  const _MoreRows({
    required this.loading,
    required this.error,
    required this.onTap,
  });
  final bool loading;
  final Object? error;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: _InlineError(error: error!),
        ),
      TextButton(
        onPressed: loading ? null : onTap,
        child: loading
            ? const FieldLoadingIndicator()
            : Text(error == null ? 'Show more' : 'Try again'),
      ),
    ],
  );
}

class _ReferralEmptyFriends extends StatelessWidget {
  const _ReferralEmptyFriends();
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: const _DashedOutline(),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: Text(
        'No one yet. Friends show up here once they join with your code.',
        style: referralText(11.5, height: 1.5),
      ),
    ),
  );
}

class _DashedOutline extends CustomPainter {
  const _DashedOutline();
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)),
      );
    final paint = Paint()
      ..color = const Color(0xFFDED8C6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      for (double start = 0; start < metric.length; start += 8) {
        canvas.drawPath(
          metric.extractPath(start, (start + 4).clamp(0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedOutline oldDelegate) => false;
}

class _UppercaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}
