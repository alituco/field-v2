import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import 'fieldrush_auth_theme.dart';

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
                  onPressed: widget.enabled
                      ? () => showCountryPicker(
                          context: context,
                          showPhoneCode: true,
                          favorite: const ['US'],
                          onSelect: (country) {
                            final iso = IsoCode.values.byName(
                              country.countryCode,
                            );
                            setState(() => _country = iso);
                            widget.onCountryChanged?.call(iso);
                          },
                        )
                      : null,
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
