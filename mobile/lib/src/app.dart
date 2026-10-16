import 'package:flutter/material.dart';

import 'auth/auth_repository.dart';
import 'auth/fieldrush_account.dart';
import 'auth/fieldrush_account_gate.dart';
import 'auth/fieldrush_account_repository.dart';
import 'config/configuration_screen.dart';
import 'home/navigation_profile_scope.dart';
import 'notifications/fieldrush_push.dart';

class FieldApp extends StatelessWidget {
  const FieldApp({
    super.key,
    required this.hasSupabaseConfig,
    this.isDev = false,
    this.profileSwitcherEnabled = false,
    this.configurationError,
    this.environmentLabel,
    this.accountRepository,
  });

  final bool hasSupabaseConfig;
  final bool isDev;
  final bool profileSwitcherEnabled;
  final String? configurationError;
  final String? environmentLabel;
  final FieldrushAccountRepository? accountRepository;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0E7A4F),
      brightness: Brightness.light,
    );

    return MaterialApp(
      title: 'Fieldrush',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        final content = _KeyboardDismissRegion(
          child: hasSupabaseConfig
              ? FieldNavigationProfileScope(
                  child: child ?? const SizedBox.shrink(),
                )
              : child ?? const SizedBox.shrink(),
        );
        final label = environmentLabel;
        if (label == null) {
          return content;
        }
        return Banner(
          message: label,
          location: BannerLocation.topEnd,
          color: label == 'LOCAL'
              ? const Color(0xFF2368F2)
              : const Color(0xFFF2A31D),
          textStyle: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.8,
          ),
          child: content,
        );
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
          ? FieldrushAccountGate(
              authRepository: SupabaseAuthRepository(
                beforeSignOut: FieldrushPush.instance.prepareForSignOut,
              ),
              accountRepository:
                  accountRepository ??
                  SupabaseFieldrushAccountRepository(
                    beforeSignOut: FieldrushPush.instance.prepareForSignOut,
                  ),
              isDev: isDev,
              profileSwitcherEnabled: profileSwitcherEnabled,
            )
          : ConfigurationScreen(error: configurationError),
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
