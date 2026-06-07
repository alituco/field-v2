import 'package:flutter/material.dart';

import 'auth/auth_gate.dart';
import 'auth/auth_repository.dart';
import 'config/configuration_screen.dart';

class FieldApp extends StatelessWidget {
  const FieldApp({super.key, required this.hasSupabaseConfig});

  final bool hasSupabaseConfig;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7A4F),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'Field',
      debugShowCheckedModeBanner: false,
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
          ? AuthGate(authRepository: SupabaseAuthRepository())
          : const ConfigurationScreen(),
    );
  }
}
