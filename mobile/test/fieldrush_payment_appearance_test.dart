import 'package:field/src/auth/fieldrush_auth_theme.dart';
import 'package:field/src/payments/fieldrush_payment_appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native payment colors use the Fieldrush review-sheet tokens', () {
    final colors = fieldrushPaymentSheetAppearance.colors!;
    expect(colors.primary, FieldrushAuthTheme.forest);
    expect(colors.background, FieldrushAuthTheme.cream);
    expect(colors.componentBackground, Colors.white);
    expect(colors.componentBorder, FieldrushAuthTheme.border);
    expect(colors.componentDivider, FieldrushAuthTheme.border);
    expect(colors.componentText, FieldrushAuthTheme.ink);
    expect(colors.primaryText, FieldrushAuthTheme.ink);
    expect(colors.secondaryText, FieldrushAuthTheme.muted);
    expect(colors.placeholderText, FieldrushAuthTheme.muted);
    expect(colors.icon, FieldrushAuthTheme.muted);
    expect(colors.error, FieldrushAuthTheme.danger);
  });

  test('native payment controls have consistent rounded, flat shapes', () {
    expect(fieldrushPaymentSheetAppearance.shapes!.borderRadius, 16);
    expect(fieldrushPaymentSheetAppearance.shapes!.borderWidth, 1);
    final button = fieldrushPaymentSheetAppearance.primaryButton!;
    expect(button.shapes!.borderWidth, 0);
    expect(button.shapes!.shadow!.opacity, 0);
  });

  test('payment button keeps Fieldrush colors in both native themes', () {
    final colors = fieldrushPaymentSheetAppearance.primaryButton!.colors!;
    for (final mode in [colors.light!, colors.dark!]) {
      expect(mode.background, FieldrushAuthTheme.forest);
      expect(mode.text, Colors.white);
      expect(mode.border, FieldrushAuthTheme.forest);
      expect(mode.successBackgroundColor, FieldrushAuthTheme.forest);
      expect(mode.successTextColor, Colors.white);
    }
    final serialized = fieldrushPaymentSheetAppearance.toJson();
    final button = serialized['primaryButton'] as Map<String, dynamic>;
    final serializedColors = button['colors'] as Map<String, dynamic>;
    expect(serializedColors['light'], serializedColors['dark']);
  });
}
