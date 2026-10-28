import 'package:flutter/material.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import 'clan.dart';
import 'clan_repository.dart';
import 'fieldrush_clan_widgets.dart';

class CustomizeClanScreen extends StatefulWidget {
  const CustomizeClanScreen({
    super.key,
    required this.clan,
    required this.clanRepository,
  });
  final Clan clan;
  final ClanRepository clanRepository;
  @override
  State<CustomizeClanScreen> createState() => _CustomizeClanScreenState();
}

class _CustomizeClanScreenState extends State<CustomizeClanScreen> {
  late final _motto = TextEditingController(text: widget.clan.motto);
  late String _color = widget.clan.themeId;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _motto.addListener(() => setState(() => _error = null));
  }

  @override
  void dispose() {
    _motto.dispose();
    super.dispose();
  }

  bool get _changed =>
      _color != widget.clan.themeId || _motto.text.trim() != widget.clan.motto;
  Future<void> _save() async {
    if (!_changed || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final clan = await widget.clanRepository.updateClanIdentity(
        clanId: widget.clan.id,
        motto: _motto.text.trim(),
        emblem: widget.clan.emblem,
        themeId: _color,
        patternId: widget.clan.patternId,
      );
      if (mounted) Navigator.of(context).pop(clan);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not save your clan. Try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      body: SafeArea(
        child: Column(
          children: [
            const FieldrushClanHeader(title: 'Edit clan', back: true),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
                children: [
                  Center(
                    child: FieldrushClanCrest(
                      tag: widget.clan.tag,
                      themeId: _color,
                      size: 84,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.clan.name,
                    textAlign: TextAlign.center,
                    style: clanTitle(17),
                  ),
                  const SizedBox(height: 20),
                  FieldrushClanCard(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'COLOR',
                          style: clanText(
                            9.5,
                            weight: FontWeight.w800,
                            color: FieldrushAuthTheme.muted,
                          ).copyWith(letterSpacing: 1.14),
                        ),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 11,
                          runSpacing: 11,
                          children: [
                            for (final color in fieldrushClanColors.entries)
                              Semantics(
                                button: true,
                                selected: _color == color.key,
                                label: color.value.$1,
                                child: InkWell(
                                  onTap: _saving
                                      ? null
                                      : () =>
                                            setState(() => _color = color.key),
                                  borderRadius: BorderRadius.circular(99),
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: color.value.$2,
                                      boxShadow: _color == color.key
                                          ? const [
                                              BoxShadow(
                                                color: FieldrushAuthTheme.ink,
                                                spreadRadius: 5.5,
                                              ),
                                              BoxShadow(
                                                color: Colors.white,
                                                spreadRadius: 3,
                                              ),
                                            ]
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'MOTTO',
                          style: clanText(
                            9.5,
                            weight: FontWeight.w800,
                            color: FieldrushAuthTheme.muted,
                          ).copyWith(letterSpacing: 1.14),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _motto,
                          enabled: !_saving,
                          maxLength: 60,
                          minLines: 1,
                          maxLines: 3,
                          style: clanText(15),
                          decoration: InputDecoration(
                            hintText: 'A few words about your crew',
                            hintStyle: clanText(
                              13,
                              color: FieldrushAuthTheme.muted,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: clanText(12, color: FieldrushAuthTheme.danger),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _changed && !_saving ? _save : null,
                    style: clanButtonStyle(height: 50),
                    child: Text(_saving ? 'Saving…' : 'Save changes'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
