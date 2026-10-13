import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../fixtures/fixture_repository.dart';
import '../home/home_discovery_repository.dart';
import '../home/home_discovery_screen.dart';
import '../profile/profile_repository.dart';
import '../profile/profile_screen.dart';
import '../ui/field_loading.dart';
import 'clan.dart';
import 'clan_detail_screen.dart';
import 'clan_repository.dart';
import 'create_clan_screen.dart';
import 'fieldrush_clan_widgets.dart';

class ClansScreen extends StatefulWidget {
  const ClansScreen({
    super.key,
    required this.clanRepository,
    required this.fixtureRepository,
    this.activationTick = 0,
  });
  final ClanRepository clanRepository;
  final FixtureRepository fixtureRepository;
  final int activationTick;
  @override
  State<ClansScreen> createState() => _ClansScreenState();
}

class _ClansScreenState extends State<ClansScreen> {
  List<Clan> _clans = const [];
  ClanMembership? _membership;
  bool _loading = true;
  String? _error;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ClansScreen old) {
    super.didUpdateWidget(old);
    if (old.activationTick != widget.activationTick) _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _error = null);
    try {
      final results = await Future.wait<dynamic>([
        widget.clanRepository.listClans(),
        widget.clanRepository.getMyClanMembership(),
      ]);
      if (!mounted || generation != _generation) return;
      setState(() {
        _clans = results[0] as List<Clan>;
        _membership = results[1] as ClanMembership?;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not load clans. Try again.',
          ),
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _create() async {
    final clan = await Navigator.of(context).push<Clan>(
      MaterialPageRoute(
        builder: (_) => CreateClanScreen(clanRepository: widget.clanRepository),
      ),
    );
    if (!mounted || clan == null) return;
    setState(() {
      _clans = [clan, ..._clans.where((c) => c.id != clan.id)];
      _membership = ClanMembership(clanId: clan.id, role: 'owner');
    });
  }

  Future<void> _browse() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HomeDiscoveryScreen(
          search: true,
          initialClans: true,
          repository: SupabaseHomeDiscoveryRepository(),
          clanRepository: widget.clanRepository,
          fixtureRepository: widget.fixtureRepository,
          onPlayer: (id) => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => Scaffold(
                backgroundColor: FieldrushAuthTheme.cream,
                body: ProfileScreen(
                  profileId: id,
                  profileRepository: SupabaseProfileRepository(),
                  clanRepository: widget.clanRepository,
                  fixtureRepository: widget.fixtureRepository,
                ),
              ),
            ),
          ),
          onNotification: (_) async {},
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final clan = _clans.where((c) => c.id == _membership?.clanId).firstOrNull;
    return Theme(
      data: FieldrushAuthTheme.theme(context),
      child: Scaffold(
        backgroundColor: FieldrushAuthTheme.cream,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              FieldrushClanHeader(
                title: 'Clans',
                action: OutlinedButton(
                  key: const ValueKey('clans-browse'),
                  onPressed: _browse,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF3C4A38),
                    side: const BorderSide(color: FieldrushAuthTheme.border),
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    shape: const StadiumBorder(),
                    textStyle: clanText(11, weight: FontWeight.w800, height: 1),
                  ),
                  child: const Text('Browse'),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: FieldLoadingContent(
                          label: 'Loading your clan',
                          rows: 3,
                        ),
                      )
                    : _error != null
                    ? ListView(
                        padding: const EdgeInsets.all(20),
                        children: [
                          Text(
                            _error!,
                            style: clanText(
                              12,
                              color: FieldrushAuthTheme.danger,
                            ),
                          ),
                          TextButton(
                            onPressed: _load,
                            child: const Text('Try again'),
                          ),
                        ],
                      )
                    : clan != null
                    ? ClanDetailScreen(
                        key: ValueKey('clan-home-${clan.id}'),
                        clan: clan,
                        clanRepository: widget.clanRepository,
                        fixtureRepository: widget.fixtureRepository,
                        currentMembership: _membership,
                        embedded: true,
                        activationTick: widget.activationTick,
                        onMembershipChanged: _load,
                      )
                    : FieldRefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 132),
                          children: [
                            FieldrushClanCard(
                              radius: 22,
                              padding: const EdgeInsets.fromLTRB(
                                20,
                                22,
                                20,
                                20,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: FieldrushDashedBox(
                                      child: Container(
                                        width: 56,
                                        height: 56,
                                        alignment: Alignment.center,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                        ),
                                        child: Text(
                                          '+',
                                          style: clanTitle(
                                            26,
                                            color: FieldrushAuthTheme.muted,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Text('Start a clan', style: clanTitle(22)),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Get your crew together now. Clan games are coming soon.',
                                    style: clanText(
                                      12.5,
                                      weight: FontWeight.w600,
                                      color: FieldrushAuthTheme.muted,
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  FilledButton(
                                    key: const ValueKey('clans-create'),
                                    onPressed: _create,
                                    style: clanButtonStyle(height: 50),
                                    child: const Text('Create a clan'),
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
        ),
      ),
    );
  }
}
