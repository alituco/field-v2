import 'package:flutter/material.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_repository.dart';
import 'config/configuration_screen.dart';

class FieldApp extends StatelessWidget {
  const FieldApp({
    super.key,
    required this.hasSupabaseConfig,
    this.isDev = false,
  });

  final bool hasSupabaseConfig;
  final bool isDev;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7A4F),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'Field',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        return _KeyboardDismissRegion(child: child ?? const SizedBox.shrink());
      },
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF7FAF8),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorScheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorScheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: colorScheme.primary, width: 2),
          ),
        ),
      ),
      home: hasSupabaseConfig
          ? AuthGate(authRepository: SupabaseAuthRepository(), isDev: isDev)
          : const ConfigurationScreen(),
    );
  }
}

class _KeyboardDismissRegion extends StatelessWidget {
  const _KeyboardDismissRegion({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: child,
    );
  }
}
