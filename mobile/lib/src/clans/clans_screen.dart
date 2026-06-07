import 'package:flutter/material.dart';

import 'clan.dart';
import 'clan_detail_screen.dart';
import 'clan_repository.dart';
import 'clan_widgets.dart';
import 'create_clan_screen.dart';

class ClansScreen extends StatefulWidget {
  const ClansScreen({super.key, required this.clanRepository});

  final ClanRepository clanRepository;

  @override
  State<ClansScreen> createState() => _ClansScreenState();
}

class _ClansScreenState extends State<ClansScreen> {
  final _searchController = TextEditingController();
  List<Clan> _clans = const [];
  bool _isLoading = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() => setState(() {}));
    _loadClans();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadClans() async {
    setState(() {
      _isLoading = true;
      _errorText = null;
    });

    try {
      final clans = await widget.clanRepository.listClans();
      if (!mounted) return;
      setState(() => _clans = clans);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText =
            'Could not load clans. Make sure the clan migration is applied in Supabase.';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _openCreateClan() async {
    final created = await Navigator.of(context).push<Clan>(
      MaterialPageRoute(
        builder: (context) =>
            CreateClanScreen(clanRepository: widget.clanRepository),
      ),
    );
    if (created == null || !mounted) return;
    setState(() => _clans = [created, ..._clans]);
  }

  List<Clan> get _filteredClans {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return _clans;
    return _clans.where((clan) {
      return clan.name.toLowerCase().contains(query) ||
          clan.tag.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filteredClans = _filteredClans;
    final recruitingCount = _clans
        .where((clan) => clan.memberCount < 11)
        .length;

    return Column(
      children: [
        FieldPageHeader(
          title: 'Clans',
          rightAction: HeaderActionButton(
            icon: Icons.add_rounded,
            label: 'New',
            onPressed: _openCreateClan,
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: fieldEmerald600,
            onRefresh: _loadClans,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: [
                FieldHeroBanner(
                  eyebrow: 'Squads · Brotherhoods · Rivals',
                  title: 'Find your tribe.',
                  subtitle:
                      'Join an elite squad or forge a new dynasty of your own.',
                  icon: Icons.shield_rounded,
                  chips: [
                    HeroChip(label: 'Clans', value: _clans.length.toString()),
                    HeroChip(
                      label: 'Recruiting',
                      value: recruitingCount.toString(),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _SearchBox(controller: _searchController),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${filteredClans.length} Clan${filteredClans.length == 1 ? '' : 's'}'
                          .toUpperCase(),
                      style: const TextStyle(
                        color: fieldGray600,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_isLoading)
                  const _ClansLoadingState()
                else if (_errorText != null)
                  _ClansErrorState(message: _errorText!, onRetry: _loadClans)
                else if (filteredClans.isEmpty)
                  _ClansEmptyState(
                    hasSearch: _searchController.text.trim().isNotEmpty,
                    onCreate: _openCreateClan,
                  )
                else ...[
                  for (var i = 0; i < filteredClans.length; i++) ...[
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: 1),
                      duration: Duration(milliseconds: 280 + (i * 45)),
                      curve: Curves.easeOutCubic,
                      builder: (context, value, child) {
                        return Opacity(
                          opacity: value,
                          child: Transform.translate(
                            offset: Offset(0, 10 * (1 - value)),
                            child: child,
                          ),
                        );
                      },
                      child: ClanCard(
                        clan: filteredClans[i],
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => ClanDetailScreen(
                                clan: filteredClans[i],
                                clanRepository: widget.clanRepository,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    if (i != filteredClans.length - 1)
                      const SizedBox(height: 12),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search clans...',
        prefixIcon: const Icon(Icons.search_rounded, color: fieldGray400),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                onPressed: controller.clear,
                icon: const Icon(Icons.close_rounded, color: fieldGray500),
                tooltip: 'Clear search',
              ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderSide: const BorderSide(color: fieldGray200),
          borderRadius: BorderRadius.circular(12),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: fieldGray200),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
}

class _ClansLoadingState extends StatelessWidget {
  const _ClansLoadingState();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++) ...[
          Container(
            height: 90,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: fieldGray200),
            ),
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          if (i != 2) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _ClansErrorState extends StatelessWidget {
  const _ClansErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _StatePanel(
      icon: Icons.warning_amber_rounded,
      title: 'Clans are not ready yet',
      message: message,
      actionLabel: 'Try again',
      onAction: onRetry,
    );
  }
}

class _ClansEmptyState extends StatelessWidget {
  const _ClansEmptyState({required this.hasSearch, required this.onCreate});

  final bool hasSearch;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    return _StatePanel(
      icon: hasSearch ? Icons.search_off_rounded : Icons.shield_outlined,
      title: hasSearch ? 'No clans found' : 'No clans yet',
      message: hasSearch
          ? 'Try a different name or tag.'
          : 'Forge the first clan and take the top of the table.',
      actionLabel: hasSearch ? null : 'Create clan',
      onAction: hasSearch ? null : onCreate,
    );
  }
}

class _StatePanel extends StatelessWidget {
  const _StatePanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, color: fieldEmerald600, size: 34),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray900,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: fieldGray500,
              fontSize: 14,
              height: 1.35,
            ),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add_rounded),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
