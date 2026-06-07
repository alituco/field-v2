import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.authRepository});

  final AuthRepository authRepository;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isSigningOut = false;

  Future<void> _signOut() async {
    setState(() => _isSigningOut = true);
    try {
      await widget.authRepository.signOut();
    } finally {
      if (mounted) {
        setState(() => _isSigningOut = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.authRepository.currentUser;
    final phone = user?.phone ?? 'Signed in';
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Field'),
        actions: [
          IconButton(
            onPressed: _isSigningOut ? null : _signOut,
            tooltip: 'Sign out',
            icon: _isSigningOut
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.check_circle,
                    color: colorScheme.primary,
                    size: 36,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Phone auth is live',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    phone,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: const Color(0xFF52635B),
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Next up: create the profile table and collect username, display name, and avatar after first sign-in.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
