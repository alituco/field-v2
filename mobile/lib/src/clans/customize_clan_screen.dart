import 'package:flutter/material.dart';

import '../core/user_facing_error.dart';
import 'clan.dart';
import 'clan_repository.dart';
import 'clan_widgets.dart';

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
  late final TextEditingController _mottoController;
  late String _emblem;
  late String _themeId;
  late String _patternId;

  bool _isSaving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _mottoController = TextEditingController(text: widget.clan.motto)
      ..addListener(_onChanged);
    _emblem = widget.clan.emblem;
    _themeId = widget.clan.themeId;
    _patternId = widget.clan.patternId;
  }

  @override
  void dispose() {
    _mottoController.dispose();
    super.dispose();
  }

  ClanTheme get _theme => clanThemeById(_themeId);

  bool get _hasChanges {
    return _mottoController.text.trim() != widget.clan.motto ||
        _emblem != widget.clan.emblem ||
        _themeId != widget.clan.themeId ||
        _patternId != widget.clan.patternId;
  }

  void _onChanged() {
    if (_errorText != null) {
      setState(() => _errorText = null);
      return;
    }
    setState(() {});
  }

  Future<void> _save() async {
    if (_isSaving || !_hasChanges) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _isSaving = true;
      _errorText = null;
    });

    try {
      final updated = await widget.clanRepository.updateClanIdentity(
        clanId: widget.clan.id,
        motto: _mottoController.text,
        emblem: _emblem,
        themeId: _themeId,
        patternId: _patternId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(updated);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorText = userFacingError(
          error,
          fallback: 'We could not save those changes. Try again.',
        );
      });
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _selectEmblem(String value) {
    setState(() {
      _emblem = value;
      _errorText = null;
    });
  }

  void _selectTheme(String value) {
    setState(() {
      _themeId = value;
      _errorText = null;
    });
  }

  void _selectPattern(String value) {
    setState(() {
      _patternId = value;
      _errorText = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: const FieldPageHeader(title: 'Customize', showBack: true),
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: fieldHeaderAwarePadding(context, top: 20, bottom: 116),
          children: [
            KitCard(
              clanName: widget.clan.name,
              clanTag: widget.clan.tag,
              motto: _mottoController.text.trim(),
              emblem: _emblem,
              theme: _theme,
              pattern: _patternId,
            ),
            const SizedBox(height: 24),
            _CustomizePanel(
              title: 'Motto',
              icon: Icons.format_quote_rounded,
              child: TextField(
                controller: _mottoController,
                maxLength: 60,
                minLines: 2,
                maxLines: 2,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  hintText: 'Tempe tempuring our way to victory',
                  counterText: '${_mottoController.text.length}/60',
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.all(16),
                  border: OutlineInputBorder(
                    borderSide: const BorderSide(color: fieldGray200),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: fieldGray200),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: const BorderSide(
                      color: fieldEmerald500,
                      width: 1.4,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                style: const TextStyle(
                  color: fieldGray900,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 16),
            _CustomizePanel(
              title: 'Color',
              icon: Icons.palette_rounded,
              child: GridView.builder(
                itemCount: clanThemes.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1,
                ),
                itemBuilder: (context, index) {
                  final option = clanThemes[index];
                  return _ThemeChoice(
                    theme: option,
                    selected: option.id == _themeId,
                    onTap: () => _selectTheme(option.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            _CustomizePanel(
              title: 'Pattern',
              icon: Icons.grid_view_rounded,
              trailing: clanPatternById(_patternId).description,
              child: GridView.builder(
                itemCount: clanPatterns.length,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.78,
                ),
                itemBuilder: (context, index) {
                  final option = clanPatterns[index];
                  return _PatternChoice(
                    pattern: option,
                    theme: _theme,
                    selected: option.id == _patternId,
                    onTap: () => _selectPattern(option.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            _CustomizePanel(
              title: 'Emblem',
              icon: Icons.emoji_events_rounded,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in clanEmblems)
                    _EmblemChoice(
                      emblem: option,
                      selected: option == _emblem,
                      onTap: () => _selectEmblem(option),
                    ),
                ],
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 16),
              _InlineError(message: _errorText!),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _CustomizeBottomBar(
        enabled: _hasChanges && !_isSaving,
        isSaving: _isSaving,
        onSave: _save,
      ),
    );
  }
}

class _CustomizePanel extends StatelessWidget {
  const _CustomizePanel({
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: fieldGray200),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: fieldGray900.withValues(alpha: 0.035),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: fieldGray100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: fieldGray700, size: 19),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: fieldGray900,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              if (trailing != null)
                Flexible(
                  child: Text(
                    trailing!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: fieldGray500,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _ThemeChoice extends StatelessWidget {
  const _ThemeChoice({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ClanTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: selected ? fieldGray900 : Colors.white,
          border: Border.all(color: selected ? fieldGray900 : fieldGray200),
          borderRadius: BorderRadius.circular(14),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: theme.from.withValues(alpha: 0.28),
                    blurRadius: 12,
                    offset: const Offset(0, 7),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [theme.from, theme.to],
                  ),
                ),
              ),
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: Text(
                  theme.name.split(' ').first.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                  ),
                ),
              ),
              if (selected)
                const Center(
                  child: CircleAvatar(
                    radius: 14,
                    backgroundColor: Colors.white,
                    child: Icon(
                      Icons.check_rounded,
                      color: fieldGray900,
                      size: 18,
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

class _PatternChoice extends StatelessWidget {
  const _PatternChoice({
    required this.pattern,
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ClanPattern pattern;
  final ClanTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: selected ? fieldGray900 : Colors.white,
          border: Border.all(color: selected ? fieldGray900 : fieldGray200),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Expanded(
              child: PatternPreview(pattern: pattern.id, theme: theme),
            ),
            const SizedBox(height: 5),
            Text(
              pattern.name.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.white : fieldGray600,
                fontSize: 8.5,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmblemChoice extends StatelessWidget {
  const _EmblemChoice({
    required this.emblem,
    required this.selected,
    required this.onTap,
  });

  final String emblem;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? fieldGray900 : fieldGray100,
          border: Border.all(color: selected ? fieldGray900 : fieldGray200),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(emblem, style: const TextStyle(fontSize: 24)),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        border: Border.all(color: const Color(0xFFFECACA)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFDC2626),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFF991B1B),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomizeBottomBar extends StatelessWidget {
  const _CustomizeBottomBar({
    required this.enabled,
    required this.isSaving,
    required this.onSave,
  });

  final bool enabled;
  final bool isSaving;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          border: const Border(top: BorderSide(color: fieldGray200)),
          boxShadow: [
            BoxShadow(
              color: fieldGray900.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        child: GestureDetector(
          onTap: enabled ? onSave : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: enabled
                  ? const LinearGradient(
                      colors: [fieldEmerald500, fieldBlue600],
                    )
                  : null,
              color: enabled ? null : fieldGray200,
              borderRadius: BorderRadius.circular(16),
              boxShadow: enabled
                  ? [
                      BoxShadow(
                        color: fieldEmerald600.withValues(alpha: 0.20),
                        blurRadius: 14,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
            ),
            child: isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_rounded, color: Colors.white, size: 22),
                      SizedBox(width: 8),
                      Text(
                        'SAVE CHANGES',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.5,
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
