import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import '../auth/fieldrush_auth_theme.dart';

/// Keep native card collection visually connected to Fieldrush's review sheet.
/// This config deliberately changes only appearance, not payment behavior.
const fieldrushPaymentSheetAppearance = PaymentSheetAppearance(
  colors: PaymentSheetAppearanceColors(
    primary: FieldrushAuthTheme.forest,
    background: FieldrushAuthTheme.cream,
    componentBackground: Colors.white,
    componentBorder: FieldrushAuthTheme.border,
    componentDivider: FieldrushAuthTheme.border,
    componentText: FieldrushAuthTheme.ink,
    primaryText: FieldrushAuthTheme.ink,
    secondaryText: FieldrushAuthTheme.muted,
    placeholderText: FieldrushAuthTheme.muted,
    icon: FieldrushAuthTheme.muted,
    error: FieldrushAuthTheme.danger,
  ),
  shapes: PaymentSheetShape(borderRadius: 16, borderWidth: 1),
  primaryButton: PaymentSheetPrimaryButtonAppearance(
    colors: PaymentSheetPrimaryButtonTheme(
      light: _primaryButtonColors,
      dark: _primaryButtonColors,
    ),
    // The button inherits the sheet's corner radius. Flutter Stripe's public
    // button-shape API exposes border width and shadow, not a separate radius.
    shapes: PaymentSheetPrimaryButtonShape(
      borderWidth: 0,
      shadow: PaymentSheetShadowParams(opacity: 0),
    ),
  ),
);

const _primaryButtonColors = PaymentSheetPrimaryButtonThemeColors(
  background: FieldrushAuthTheme.forest,
  text: Colors.white,
  border: FieldrushAuthTheme.forest,
  successBackgroundColor: FieldrushAuthTheme.forest,
  successTextColor: Colors.white,
);
