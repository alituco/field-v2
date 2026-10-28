import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/fieldrush_auth_theme.dart';
import '../core/user_facing_error.dart';
import '../markets/fieldrush_city.dart';
import '../markets/fieldrush_city_repository.dart';
import 'clan_repository.dart';
import 'fieldrush_clan_widgets.dart';

class CreateClanScreen extends StatefulWidget {
  const CreateClanScreen({
    super.key,
    required this.clanRepository,
    this.cityRepository,
  });
  final ClanRepository clanRepository;
  final FieldrushCityRepository? cityRepository;
  @override
  State<CreateClanScreen> createState() => _CreateClanScreenState();
}

class _CreateClanScreenState extends State<CreateClanScreen> {
  final _name = TextEditingController();
  final _tag = TextEditingController();
  String _color = 'pitch';
  bool _saving = false;
  String? _error;
  FieldrushCity? _city;
  bool _tagEdited = false;
  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _tag.addListener(() => setState(() => _error = null));
    final repository =
        widget.cityRepository ??
        (widget.clanRepository is SupabaseClanRepository
            ? SupabaseFieldrushCityRepository()
            : null);
    if (repository == null) {
      _city = FieldrushCity.phoenix;
    } else {
      repository
          .loadPreferredCity()
          .then((city) {
            if (mounted) setState(() => _city = city);
          })
          .catchError((Object error) {
            if (mounted) {
              setState(
                () => _error = userFacingError(
                  error,
                  fallback: 'Could not load your city. Try again.',
                ),
              );
            }
          });
    }
  }

  void _changed() {
    if (!_tagEdited) {
      final words = _name.text
          .trim()
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList();
      final suggestion = words.isEmpty
          ? ''
          : words.length > 1
          ? words.take(3).map((w) => w[0]).join()
          : words.first.substring(0, words.first.length.clamp(0, 3));
      _tag.text = suggestion.replaceAll(RegExp('[^a-zA-Z]'), '').toUpperCase();
    }
    setState(() => _error = null);
  }

  @override
  void dispose() {
    _name.dispose();
    _tag.dispose();
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().length >= 3 &&
      _name.text.trim().length <= 24 &&
      RegExp(r'^[A-Z]{2,3}$').hasMatch(_tag.text.trim()) &&
      _city != null;
  Future<void> _create() async {
    if (!_valid || _saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final clan = await widget.clanRepository.createClan(
        name: _name.text.trim(),
        tag: _tag.text.trim(),
        motto: '',
        emblem: '⚽',
        themeId: _color,
        patternId: 'solid',
      );
      if (mounted) Navigator.of(context).pop(clan);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = userFacingError(
            error,
            fallback: 'Could not create your clan. Try again.',
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
            const FieldrushClanHeader(title: 'Create a clan', back: true),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 40),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  Center(
                    child: FieldrushClanCrest(
                      tag: _tag.text.isEmpty ? '?' : _tag.text,
                      themeId: _color,
                      size: 84,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _name.text.trim().isEmpty ? 'Your clan' : _name.text.trim(),
                    textAlign: TextAlign.center,
                    style: clanTitle(17),
                  ),
                  const SizedBox(height: 20),
                  FieldrushClanCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _input(
                          'CLAN NAME',
                          _name,
                          'e.g. Desert Rattlers',
                          maxLength: 24,
                          key: 'clan-create-name',
                        ),
                        const Divider(height: 1, color: Color(0xFFF0ECE0)),
                        _input(
                          'TAG',
                          _tag,
                          'DR',
                          maxLength: 3,
                          key: 'clan-create-tag',
                          tag: true,
                        ),
                        const Divider(height: 1, color: Color(0xFFF0ECE0)),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
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
                              const SizedBox(height: 11),
                              Wrap(
                                spacing: 11,
                                runSpacing: 11,
                                children: [
                                  for (final option
                                      in fieldrushClanColors.entries)
                                    Semantics(
                                      button: true,
                                      selected: _color == option.key,
                                      label: option.value.$1,
                                      child: InkWell(
                                        key: ValueKey(
                                          'clan-color-${option.key}',
                                        ),
                                        onTap: _saving
                                            ? null
                                            : () => setState(
                                                () => _color = option.key,
                                              ),
                                        borderRadius: BorderRadius.circular(99),
                                        child: Container(
                                          width: 40,
                                          height: 40,
                                          decoration: BoxDecoration(
                                            color: option.value.$2,
                                            shape: BoxShape.circle,
                                            boxShadow: _color == option.key
                                                ? const [
                                                    BoxShadow(
                                                      color: FieldrushAuthTheme
                                                          .ink,
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
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'Home city: ${_city?.label ?? 'Loading…'}. You’ll be the captain.',
                      style: clanText(
                        11.5,
                        weight: FontWeight.w600,
                        color: FieldrushAuthTheme.muted,
                        height: 1.45,
                      ),
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
                    key: const ValueKey('clan-create-submit'),
                    onPressed: _valid && !_saving ? _create : null,
                    style: clanButtonStyle(height: 50),
                    child: Text(_saving ? 'Creating…' : 'Create clan'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _input(
    String label,
    TextEditingController controller,
    String placeholder, {
    required int maxLength,
    required String key,
    bool tag = false,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: clanText(
            9.5,
            weight: FontWeight.w800,
            color: FieldrushAuthTheme.muted,
          ).copyWith(letterSpacing: 1.14),
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey(key),
          controller: controller,
          enabled: !_saving,
          maxLength: maxLength,
          textCapitalization: tag
              ? TextCapitalization.characters
              : TextCapitalization.words,
          inputFormatters: tag
              ? [
                  FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
                  TextInputFormatter.withFunction(
                    (old, next) => next.copyWith(text: next.text.toUpperCase()),
                  ),
                ]
              : null,
          onChanged: tag ? (_) => _tagEdited = true : null,
          style: clanText(
            15,
          ).copyWith(height: 1.3, letterSpacing: tag ? .9 : 0),
          decoration: InputDecoration(
            hintText: placeholder,
            hintStyle: clanText(15, color: const Color(0xFF9A9583)),
            isDense: true,
            contentPadding: EdgeInsets.zero,
            counterText: '',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
        if (!tag) ...[
          const SizedBox(height: 7),
          Text(
            '3–24 characters',
            style: clanText(
              10.5,
              weight: FontWeight.w600,
              color: FieldrushAuthTheme.muted,
              height: 1.3,
            ),
          ),
        ],
        if (tag) ...[
          const SizedBox(height: 7),
          Text(
            '2–3 letters on your crest',
            style: clanText(
              10.5,
              weight: FontWeight.w600,
              color: FieldrushAuthTheme.muted,
              height: 1.3,
            ),
          ),
        ],
      ],
    ),
  );
}
