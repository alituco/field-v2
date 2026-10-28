import 'package:flutter/material.dart';

import 'fieldrush_auth_theme.dart';
import 'player_identity.dart';

class StaffIdentityScreen extends StatelessWidget {
  const StaffIdentityScreen({super.key, required this.onUsePlayerAccount});

  final Future<void> Function() onUsePlayerAccount;

  @override
  Widget build(BuildContext context) => Theme(
    data: FieldrushAuthTheme.theme(context),
    child: Scaffold(
      backgroundColor: FieldrushAuthTheme.cream,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Staff account',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                const Text(
                  staffAccountOnlyMessage,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onUsePlayerAccount,
                  child: const Text('Use a player account'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
