import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'fieldrush_auth_theme.dart';
import '../ui/fieldrush_modal.dart';

/// Accepts national input in the selected country or a pasted +E.164 number.
String? normalizeFieldrushPhone(String input, {IsoCode country = IsoCode.US}) {
  final value = input.trim();
  if (value.isEmpty || RegExp(r'[^\d+\s().-]').hasMatch(value)) return null;
  try {
    final parsed = PhoneNumber.parse(
      value,
      destinationCountry: value.startsWith('+') ? null : country,
    );
    return parsed.isValid() ? parsed.international : null;
  } catch (_) {
    return null;
  }
}

class FieldrushPhoneField extends StatefulWidget {
  const FieldrushPhoneField({
    super.key,
    required this.controller,
    this.enabled = true,
    this.initialCountry = IsoCode.US,
    this.onCountryChanged,
    this.errorText,
  });

  final TextEditingController controller;
  final bool enabled;
  final IsoCode initialCountry;
  final ValueChanged<IsoCode>? onCountryChanged;
  final String? errorText;

  @override
  State<FieldrushPhoneField> createState() => _FieldrushPhoneFieldState();
}

class _FieldrushPhoneFieldState extends State<FieldrushPhoneField> {
  late IsoCode _country;

  @override
  void initState() {
    super.initState();
    _country = widget.initialCountry;
  }

  @override
  void didUpdateWidget(covariant FieldrushPhoneField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialCountry != widget.initialCountry) {
      _country = widget.initialCountry;
    }
  }

  Future<void> _chooseCountry() async {
    final country = await showFieldrushModal<IsoCode>(
      context: context,
      builder: (_) => _PhoneCountrySheet(selected: _country),
    );
    if (!mounted || country == null) return;
    setState(() => _country = country);
    widget.onCountryChanged?.call(country);
  }

  @override
  Widget build(BuildContext context) {
    final dialCode = PhoneNumber(isoCode: _country, nsn: '').countryCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: FieldrushAuthTheme.forest, width: 2.5),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Semantics(
                label: 'Country calling code, ${_country.name}, plus $dialCode',
                button: true,
                child: TextButton(
                  key: const Key('fieldrush-country-picker'),
                  onPressed: widget.enabled ? _chooseCountry : null,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.only(right: 8),
                    foregroundColor: FieldrushAuthTheme.muted,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '+$dialCode',
                        style: const TextStyle(
                          fontFamily: 'Outfit',
                          fontWeight: FontWeight.w700,
                          fontSize: 26,
                        ),
                      ),
                      const Icon(Icons.keyboard_arrow_down, size: 18),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Semantics(
                  label: 'Phone number',
                  child: TextField(
                    key: const Key('fieldrush-phone'),
                    controller: widget.controller,
                    enabled: widget.enabled,
                    keyboardType: TextInputType.phone,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    textInputAction: TextInputAction.done,
                    style: const TextStyle(
                      fontFamily: 'Outfit',
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      color: FieldrushAuthTheme.ink,
                    ),
                    decoration: InputDecoration(
                      hintText: _country == IsoCode.US
                          ? '(602) 555-0148'
                          : 'Phone number',
                      hintStyle: const TextStyle(
                        color: FieldrushAuthTheme.muted,
                        fontFamily: 'Outfit',
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (widget.errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              widget.errorText!,
              style: const TextStyle(color: FieldrushAuthTheme.danger),
            ),
          ),
      ],
    );
  }
}

class _PhoneCountrySheet extends StatefulWidget {
  const _PhoneCountrySheet({required this.selected});
  final IsoCode selected;

  @override
  State<_PhoneCountrySheet> createState() => _PhoneCountrySheetState();
}

class _PhoneCountrySheetState extends State<_PhoneCountrySheet> {
  final _search = TextEditingController();
  late final List<Country> _countries;

  @override
  void initState() {
    super.initState();
    final supported = IsoCode.values.map((code) => code.name).toSet();
    _countries =
        CountryService()
            .getAll()
            .where((country) => supported.contains(country.countryCode))
            .toList()
          ..sort((a, b) {
            if (a.countryCode == 'US') return -1;
            if (b.countryCode == 'US') return 1;
            return a.name.compareTo(b.name);
          });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final digits = query.replaceAll('+', '');
    final countries = _countries
        .where(
          (country) =>
              country.name.toLowerCase().contains(query) ||
              country.countryCode.toLowerCase().contains(query) ||
              country.phoneCode.startsWith(digits),
        )
        .toList();
    return FieldrushModal(
      key: const ValueKey('fieldrush-phone-country-sheet'),
      title: 'Country calling code',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('fieldrush-phone-country-search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              hintText: 'Search country or calling code',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(height: 14),
          if (countries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('No matching countries.'),
            ),
          if (countries.isNotEmpty)
            SizedBox(
              height: (MediaQuery.sizeOf(context).height * .4).clamp(
                160.0,
                360.0,
              ),
              child: ListView(
                key: const ValueKey('fieldrush-phone-country-list'),
                children: [
                  for (final country in countries)
                    Semantics(
                      key: ValueKey(
                        'fieldrush-phone-country-semantics-${country.countryCode}',
                      ),
                      button: true,
                      selected: country.countryCode == widget.selected.name,
                      label: '${country.name}, plus ${country.phoneCode}',
                      excludeSemantics: true,
                      onTap: () => Navigator.pop(
                        context,
                        IsoCode.values.byName(country.countryCode),
                      ),
                      child: Material(
                        color: Colors.white,
                        child: InkWell(
                          key: ValueKey(
                            'fieldrush-phone-country-${country.countryCode}',
                          ),
                          onTap: () => Navigator.pop(
                            context,
                            IsoCode.values.byName(country.countryCode),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 14,
                            ),
                            decoration: const BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: FieldrushAuthTheme.border,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  country.flagEmoji,
                                  style: const TextStyle(fontSize: 22),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    country.name,
                                    style: FieldrushModal.bodyStyle.copyWith(
                                      color: FieldrushAuthTheme.ink,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text('+${country.phoneCode}'),
                                if (country.countryCode ==
                                    widget.selected.name) ...[
                                  const SizedBox(width: 8),
                                  const Icon(
                                    Icons.check_rounded,
                                    color: FieldrushAuthTheme.forest,
                                    size: 18,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        OutlinedButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
