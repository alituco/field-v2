import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/user_facing_error.dart';
import 'clan.dart';
import 'clan_repository.dart';
import 'clan_widgets.dart';

class CreateClanScreen extends StatefulWidget {
  const CreateClanScreen({super.key, required this.clanRepository});

  final ClanRepository clanRepository;

  @override
  State<CreateClanScreen> createState() => _CreateClanScreenState();
}

class _CreateClanScreenState extends State<CreateClanScreen>
    with TickerProviderStateMixin {
  final _nameController = TextEditingController();
  final _tagController = TextEditingController();
  final _mottoController = TextEditingController();

  late final AnimationController _confettiController;

  int _step = 0;
  int _direction = 1;
  String _emblem = '⚽';
  String _themeId = 'pitch';
  String _patternId = 'solid';
  bool _isSaving = false;
  String? _errorText;
  Clan? _createdClan;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(_onFieldChanged);
    _tagController.addListener(_onFieldChanged);
    _mottoController.addListener(_onFieldChanged);
    _confettiController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _tagController.dispose();
    _mottoController.dispose();
    _confettiController.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (_errorText != null) {
      setState(() => _errorText = null);
      return;
    }
    setState(() {});
  }

  ClanTheme get _theme => clanThemeById(_themeId);

  bool get _canAdvance {
    return switch (_step) {
      0 =>
        _nameController.text.trim().length >= 2 &&
            _tagController.text.trim().length >= 2,
      1 => _emblem.trim().isNotEmpty,
      2 => _themeId.isNotEmpty && _patternId.isNotEmpty,
      _ => false,
    };
  }

  void _goToStep(int next) {
    setState(() {
      _direction = next > _step ? 1 : -1;
      _step = next;
      _errorText = null;
    });
  }

  void _back() {
    if (_step == 0 || _step == 3) {
      Navigator.of(context).pop(_createdClan);
      return;
    }
    _goToStep(_step - 1);
  }

  void _randomize() {
    final random = math.Random();
    setState(() {
      _emblem = clanEmblems[random.nextInt(clanEmblems.length)];
      _themeId = clanThemes[random.nextInt(clanThemes.length)].id;
      _patternId = clanPatterns[random.nextInt(clanPatterns.length)].id;
      _errorText = null;
    });
  }

  Future<void> _handlePrimaryAction() async {
    if (_step == 3) {
      Navigator.of(context).pop(_createdClan);
      return;
    }

    if (!_canAdvance || _isSaving) return;
    if (_step < 2) {
      _goToStep(_step + 1);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isSaving = true;
      _errorText = null;
    });

    try {
      final clan = await widget.clanRepository.createClan(
        name: _nameController.text,
        tag: _tagController.text,
        motto: _mottoController.text,
        emblem: _emblem,
        themeId: _themeId,
        patternId: _patternId,
      );
      if (!mounted) return;
      setState(() {
        _createdClan = clan;
        _direction = 1;
        _step = 3;
      });
      _confettiController.forward(from: 0);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _errorText = userFacingError(
          error,
          fallback: 'We could not create your clan. Try again.',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: fieldBackground,
      body: FieldHeaderOverlay(
        header: _CreateClanHeader(
          step: _step,
          onBack: _back,
          onRandomize: _step < 2 ? _randomize : null,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: SingleChildScrollView(
                padding: fieldHeaderAwarePadding(
                  context,
                  bottom: _step == 3 ? 112 : 148,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    final slide = Tween<Offset>(
                      begin: Offset(_direction * 0.08, 0),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: slide, child: child),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey(_step),
                    child: _buildStep(),
                  ),
                ),
              ),
            ),
            if (_step == 3)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _confettiController,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _ConfettiPainter(
                          progress: _confettiController.value,
                          colors: [
                            _theme.from,
                            _theme.to,
                            _theme.accent,
                            const Color(0xFFF59E0B),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: _CreateClanBottomBar(
                  step: _step,
                  canAdvance: _canAdvance,
                  isSaving: _isSaving,
                  theme: _theme,
                  onPressed: _handlePrimaryAction,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep() {
    return switch (_step) {
      0 => _IdentityStep(
        nameController: _nameController,
        tagController: _tagController,
        mottoController: _mottoController,
        emblem: _emblem,
        theme: _theme,
        patternId: _patternId,
        errorText: _errorText,
      ),
      1 => _EmblemStep(
        name: _nameController.text.trim(),
        tag: _tagController.text.trim(),
        motto: _mottoController.text.trim(),
        emblem: _emblem,
        theme: _theme,
        patternId: _patternId,
        onSelected: (value) => setState(() => _emblem = value),
      ),
      2 => _KitStep(
        name: _nameController.text.trim(),
        tag: _tagController.text.trim(),
        motto: _mottoController.text.trim(),
        emblem: _emblem,
        themeId: _themeId,
        patternId: _patternId,
        onThemeSelected: (value) => setState(() => _themeId = value),
        onPatternSelected: (value) => setState(() => _patternId = value),
        errorText: _errorText,
      ),
      _ => _RevealStep(
        name: _nameController.text.trim(),
        tag: _tagController.text.trim(),
        motto: _mottoController.text.trim(),
        emblem: _emblem,
        theme: _theme,
        patternId: _patternId,
      ),
    };
  }
}

class _CreateClanHeader extends StatelessWidget {
  const _CreateClanHeader({
    required this.step,
    required this.onBack,
    required this.onRandomize,
  });

  final int step;
  final VoidCallback onBack;
  final VoidCallback? onRandomize;

  static const labels = ['Identity', 'Emblem', 'Kit', 'Glory'];

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;

    return SizedBox(
      height: topInset + 70,
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.38),
              border: Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.28)),
              ),
              boxShadow: [
                BoxShadow(
                  color: fieldGray900.withValues(alpha: 0.035),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: EdgeInsets.only(top: topInset),
              child: Column(
                children: [
                  SizedBox(
                    height: 52,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            onPressed: onBack,
                            icon: const Icon(Icons.chevron_left_rounded),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.62,
                              ),
                              foregroundColor: fieldGray700,
                            ),
                          ),
                          Text(
                            labels[step].toUpperCase(),
                            style: const TextStyle(
                              color: fieldGray700,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2.6,
                            ),
                          ),
                          SizedBox(
                            width: 72,
                            child: onRandomize == null
                                ? const SizedBox()
                                : TextButton.icon(
                                    onPressed: onRandomize,
                                    icon: const Icon(
                                      Icons.shuffle_rounded,
                                      size: 14,
                                    ),
                                    label: const Text('Random'),
                                    style: TextButton.styleFrom(
                                      foregroundColor: fieldEmerald600,
                                      textStyle: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.5,
                                      ),
                                      padding: EdgeInsets.zero,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        for (var i = 0; i < labels.length; i++) ...[
                          Expanded(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 280),
                              curve: Curves.easeOutCubic,
                              height: 6,
                              decoration: BoxDecoration(
                                color: i < step
                                    ? fieldEmerald500
                                    : i == step
                                    ? null
                                    : fieldGray200,
                                gradient: i == step
                                    ? const LinearGradient(
                                        colors: [fieldEmerald500, fieldBlue600],
                                      )
                                    : null,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          if (i != labels.length - 1) const SizedBox(width: 6),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _IdentityStep extends StatelessWidget {
  const _IdentityStep({
    required this.nameController,
    required this.tagController,
    required this.mottoController,
    required this.emblem,
    required this.theme,
    required this.patternId,
    required this.errorText,
  });

  final TextEditingController nameController;
  final TextEditingController tagController;
  final TextEditingController mottoController;
  final String emblem;
  final ClanTheme theme;
  final String patternId;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('identity'),
      children: [
        const _StepTitle(
          title: 'Build your legacy',
          subtitle: 'Forge a name that strikes fear into rivals.',
        ),
        const SizedBox(height: 20),
        KitCard(
          clanName: nameController.text.trim().isEmpty
              ? 'YOUR CLAN'
              : nameController.text.trim(),
          clanTag: tagController.text.trim().isEmpty
              ? 'TAG'
              : tagController.text,
          motto: mottoController.text.trim().isEmpty
              ? 'Your motto here.'
              : mottoController.text.trim(),
          emblem: emblem,
          theme: theme,
          pattern: patternId,
          preview: true,
        ),
        const SizedBox(height: 24),
        _FieldLabel(
          label: 'Clan Name',
          hint: '${nameController.text.length}/24',
        ),
        _TextInput(
          controller: nameController,
          hint: 'Thunder FC',
          maxLength: 24,
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 16),
        _FieldLabel(label: 'Tag', hint: '${tagController.text.length}/5'),
        _TagInput(controller: tagController),
        const SizedBox(height: 16),
        _FieldLabel(
          label: 'Motto',
          hint: '${mottoController.text.length}/60',
          optional: true,
        ),
        _TextInput(
          controller: mottoController,
          hint: 'Never bend the knee.',
          maxLength: 60,
          minLines: 2,
          maxLines: 2,
        ),
        if (errorText != null) ...[
          const SizedBox(height: 16),
          _InlineError(message: errorText!),
        ],
      ],
    );
  }
}

class _EmblemStep extends StatelessWidget {
  const _EmblemStep({
    required this.name,
    required this.tag,
    required this.motto,
    required this.emblem,
    required this.theme,
    required this.patternId,
    required this.onSelected,
  });

  final String name;
  final String tag;
  final String motto;
  final String emblem;
  final ClanTheme theme;
  final String patternId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('emblem'),
      children: [
        const _StepTitle(
          title: 'Pick your emblem',
          subtitle: 'The symbol your rivals will learn to fear.',
        ),
        const SizedBox(height: 20),
        KitCard(
          clanName: name,
          clanTag: tag,
          motto: motto,
          emblem: emblem,
          theme: theme,
          pattern: patternId,
        ),
        const SizedBox(height: 24),
        GridView.builder(
          itemCount: clanEmblems.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 6,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemBuilder: (context, index) {
            final option = clanEmblems[index];
            final selected = option == emblem;
            return _ChoiceTile(
              selected: selected,
              onTap: () => onSelected(option),
              child: Text(
                option,
                style: TextStyle(
                  fontSize: 24,
                  shadows: selected ? _selectedShadows : null,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _KitStep extends StatelessWidget {
  const _KitStep({
    required this.name,
    required this.tag,
    required this.motto,
    required this.emblem,
    required this.themeId,
    required this.patternId,
    required this.onThemeSelected,
    required this.onPatternSelected,
    required this.errorText,
  });

  final String name;
  final String tag;
  final String motto;
  final String emblem;
  final String themeId;
  final String patternId;
  final ValueChanged<String> onThemeSelected;
  final ValueChanged<String> onPatternSelected;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final theme = clanThemeById(themeId);
    return Column(
      key: const ValueKey('kit'),
      children: [
        const _StepTitle(
          title: 'Design the kit',
          subtitle: 'Color & pattern — make it unmistakable.',
        ),
        const SizedBox(height: 20),
        KitCard(
          clanName: name,
          clanTag: tag,
          motto: motto,
          emblem: emblem,
          theme: theme,
          pattern: patternId,
        ),
        const SizedBox(height: 24),
        const _SubLabel('Color'),
        GridView.builder(
          itemCount: clanThemes.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
          ),
          itemBuilder: (context, index) {
            final option = clanThemes[index];
            final selected = option.id == themeId;
            return _ThemeTile(
              theme: option,
              selected: selected,
              onTap: () => onThemeSelected(option.id),
            );
          },
        ),
        const SizedBox(height: 20),
        const _SubLabel('Pattern'),
        GridView.builder(
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
            final selected = option.id == patternId;
            return _PatternTile(
              pattern: option,
              selected: selected,
              theme: theme,
              onTap: () => onPatternSelected(option.id),
            );
          },
        ),
        const SizedBox(height: 8),
        Text(
          clanPatternById(patternId).description,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (errorText != null) ...[
          const SizedBox(height: 16),
          _InlineError(message: errorText!),
        ],
      ],
    );
  }
}

class _RevealStep extends StatelessWidget {
  const _RevealStep({
    required this.name,
    required this.tag,
    required this.motto,
    required this.emblem,
    required this.theme,
    required this.patternId,
  });

  final String name;
  final String tag;
  final String motto;
  final String emblem;
  final ClanTheme theme;
  final String patternId;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: const ValueKey('reveal'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 620),
      curve: Curves.easeOutBack,
      builder: (context, value, child) {
        return Opacity(
          opacity: value.clamp(0, 1),
          child: Transform.scale(scale: 0.92 + (value * 0.08), child: child),
        );
      },
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.auto_awesome_rounded,
                  color: Color(0xFFF59E0B),
                  size: 18,
                ),
                SizedBox(width: 8),
                Text(
                  'A CLAN IS BORN',
                  style: TextStyle(
                    color: Color(0xFFF59E0B),
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.5,
                  ),
                ),
                SizedBox(width: 8),
                Icon(
                  Icons.auto_awesome_rounded,
                  color: Color(0xFFF59E0B),
                  size: 18,
                ),
              ],
            ),
            const SizedBox(height: 24),
            KitCard(
              clanName: name,
              clanTag: tag,
              motto: motto,
              emblem: emblem,
              theme: theme,
              pattern: patternId,
              large: true,
            ),
            const SizedBox(height: 24),
            const Text(
              'The pitch is yours. Rally your squad and stake your claim on the table.',
              textAlign: TextAlign.center,
              style: TextStyle(color: fieldGray600, fontSize: 15, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title.toUpperCase(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: fieldGray900,
            fontSize: 30,
            height: 1.05,
            fontWeight: FontWeight.w900,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: fieldGray500,
            fontSize: 14,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({
    required this.label,
    required this.hint,
    this.optional = false,
  });

  final String label;
  final String hint;
  final bool optional;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: fieldGray700,
              fontSize: 12,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.4,
            ),
          ),
          if (optional) ...[
            const SizedBox(width: 6),
            const Text(
              'OPTIONAL',
              style: TextStyle(
                color: fieldGray400,
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
          ],
          const Spacer(),
          Text(
            hint,
            style: const TextStyle(
              color: fieldGray400,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _TextInput extends StatelessWidget {
  const _TextInput({
    required this.controller,
    required this.hint,
    required this.maxLength,
    this.minLines = 1,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.sentences,
  });

  final TextEditingController controller;
  final String hint;
  final int maxLength;
  final int minLines;
  final int maxLines;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLength: maxLength,
      minLines: minLines,
      maxLines: maxLines,
      textCapitalization: textCapitalization,
      style: const TextStyle(fontWeight: FontWeight.w800, color: fieldGray900),
      decoration: InputDecoration(
        hintText: hint,
        counterText: '',
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: fieldGray200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: fieldGray200),
        ),
      ),
    );
  }
}

class _TagInput extends StatelessWidget {
  const _TagInput({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        TextField(
          controller: controller,
          maxLength: 5,
          textAlign: TextAlign.center,
          textCapitalization: TextCapitalization.characters,
          style: const TextStyle(
            color: fieldGray900,
            fontSize: 16,
            fontWeight: FontWeight.w900,
            letterSpacing: 2,
          ),
          onChanged: (value) {
            final cleaned = value.toUpperCase().replaceAll(
              RegExp(r'[^A-Z0-9]'),
              '',
            );
            if (cleaned == value) return;
            controller.value = TextEditingValue(
              text: cleaned,
              selection: TextSelection.collapsed(offset: cleaned.length),
            );
          },
          decoration: InputDecoration(
            hintText: 'TFC',
            counterText: '',
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 40,
              vertical: 16,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: fieldGray200),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: fieldGray200),
            ),
          ),
        ),
        const Positioned(
          left: 16,
          child: Text(
            '[',
            style: TextStyle(
              color: fieldGray400,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const Positioned(
          right: 16,
          child: Text(
            ']',
            style: TextStyle(
              color: fieldGray400,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
      ],
    );
  }
}

class _SubLabel extends StatelessWidget {
  const _SubLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: fieldGray700,
            fontSize: 12,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.4,
          ),
        ),
      ),
    );
  }
}

class _ChoiceTile extends StatefulWidget {
  const _ChoiceTile({
    required this.selected,
    required this.child,
    required this.onTap,
  });

  final bool selected;
  final Widget child;
  final VoidCallback onTap;

  @override
  State<_ChoiceTile> createState() => _ChoiceTileState();
}

class _ChoiceTileState extends State<_ChoiceTile> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed
            ? 0.9
            : widget.selected
            ? 1.05
            : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            gradient: widget.selected
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [fieldEmerald500, fieldBlue600],
                  )
                : null,
            color: widget.selected ? null : Colors.white,
            border: Border.all(
              color: widget.selected ? Colors.white : fieldGray200,
              width: widget.selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: widget.selected
                ? [
                    BoxShadow(
                      color: fieldEmerald500.withValues(alpha: 0.30),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: Center(child: widget.child),
        ),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ClanTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _ChoiceTile(
      selected: selected,
      onTap: onTap,
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
            if (selected)
              const Center(
                child: CircleAvatar(
                  radius: 15,
                  backgroundColor: Colors.white,
                  child: Icon(
                    Icons.check_rounded,
                    color: fieldGray900,
                    size: 18,
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 6,
              child: Text(
                theme.name.split(' ').first.toUpperCase(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.6,
                  shadows: [Shadow(color: Colors.black38, blurRadius: 3)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PatternTile extends StatelessWidget {
  const _PatternTile({
    required this.pattern,
    required this.selected,
    required this.theme,
    required this.onTap,
  });

  final ClanPattern pattern;
  final bool selected;
  final ClanTheme theme;
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
          border: selected ? null : Border.all(color: fieldGray200),
          borderRadius: BorderRadius.circular(12),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.20),
                    blurRadius: 10,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
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
                color: selected ? Colors.white : fieldGray700,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
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
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF991B1B),
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _CreateClanBottomBar extends StatelessWidget {
  const _CreateClanBottomBar({
    required this.step,
    required this.canAdvance,
    required this.isSaving,
    required this.theme,
    required this.onPressed,
  });

  final int step;
  final bool canAdvance;
  final bool isSaving;
  final ClanTheme theme;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = step == 3 || (canAdvance && !isSaving);
    final label = switch (step) {
      2 => isSaving ? 'Forging Clan' : 'Forge Clan',
      3 => 'Enter the Field',
      _ => 'Continue',
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.95),
        border: const Border(top: BorderSide(color: fieldGray100)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: FilledButton(
          onPressed: enabled ? onPressed : null,
          style: FilledButton.styleFrom(
            backgroundColor: enabled ? null : fieldGray200,
            foregroundColor: enabled ? Colors.white : fieldGray400,
            disabledBackgroundColor: fieldGray200,
            disabledForegroundColor: fieldGray400,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            padding: EdgeInsets.zero,
          ),
          child: Ink(
            decoration: enabled
                ? BoxDecoration(
                    gradient: LinearGradient(
                      colors: step == 3
                          ? [theme.from, theme.to]
                          : [fieldEmerald600, fieldEmerald500, fieldBlue600],
                    ),
                    borderRadius: BorderRadius.circular(16),
                  )
                : null,
            child: Container(
              alignment: Alignment.center,
              child: isSaving
                  ? const Text(
                      'Creating clan…',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (step == 2) ...[
                          const Icon(Icons.bolt_rounded, size: 20),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          label.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  const _ConfettiPainter({required this.progress, required this.colors});

  final double progress;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final random = math.Random(12);
    final paint = Paint();
    final eased = Curves.easeOut.transform(progress.clamp(0, 1));

    for (var i = 0; i < 70; i++) {
      final side = i.isEven ? 0.18 : 0.82;
      final startX = size.width * (side + ((random.nextDouble() - 0.5) * 0.14));
      final startY = -24 - (random.nextDouble() * 70);
      final drift = (random.nextDouble() - 0.5) * size.width * 0.70;
      final fall = size.height * (0.18 + random.nextDouble() * 0.95);
      final x = startX + (drift * eased);
      final y = startY + (fall * eased) + (math.sin(eased * math.pi + i) * 24);
      if (y > size.height + 24) continue;
      paint.color = colors[i % colors.length].withValues(alpha: 1 - progress);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate((progress * math.pi * 4) + i);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: 5 + random.nextDouble() * 5,
            height: 8 + random.nextDouble() * 7,
          ),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.colors != colors;
  }
}

const _selectedShadows = [
  Shadow(color: Colors.black26, blurRadius: 3, offset: Offset(0, 1)),
];
