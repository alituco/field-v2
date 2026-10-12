import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/fieldrush_auth_theme.dart';

/// Apple's glass material, with a frosted fallback for older OS versions.
/// Controls stay in Flutter so navigation, focus and semantics remain shared.
class NativeGlassSurface extends StatefulWidget {
  const NativeGlassSurface({super.key});

  @override
  State<NativeGlassSurface> createState() => _NativeGlassSurfaceState();
}

class _NativeGlassSurfaceState extends State<NativeGlassSurface> {
  static const _channel = MethodChannel('fieldrush/liquid_glass_support');
  bool _nativeGlass = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      _checkSupport();
    }
  }

  Future<void> _checkSupport() async {
    try {
      // Older iOS uses native blur, which also honors Reduce Transparency.
      final supported = await _channel.invokeMethod<bool>('isAvailable');
      if (mounted && supported == true) {
        setState(() => _nativeGlass = true);
      }
    } on MissingPluginException {
      // Widget tests and older running builds still get the frosted surface.
    } on PlatformException {
      // Navigation must stay usable if the native material is unavailable.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_nativeGlass) {
      return const ExcludeSemantics(
        child: IgnorePointer(
          child: UiKitView(
            viewType: 'fieldrush/liquid_glass',
            layoutDirection: TextDirection.ltr,
          ),
        ),
      );
    }
    final highContrast = MediaQuery.highContrastOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: FieldrushAuthTheme.cream.withValues(
              alpha: highContrast ? .98 : .62,
            ),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: .8)),
          ),
        ),
      ),
    );
  }
}
